#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <rte_branch_prediction.h>
#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ether.h>
#include <rte_ethdev.h>
#include <rte_event_eth_rx_adapter.h>
#include <rte_event_eth_tx_adapter.h>
#include <rte_eventdev.h>
#include <rte_mbuf.h>

#define RX_RING_SIZE 1024
#define TX_RING_SIZE 1024
#define NUM_MBUFS 8192
#define MBUF_CACHE_SIZE 256
#define MAX_RULES 4096
#define MAX_REPLICAS 32
#define MAX_L2_ENDPOINTS 1024
#define DEFAULT_BURST 64
#define DEDUP_TABLE_SIZE 16384
#define MAX_DELAY_Q 131072

struct mac_rule {
    struct rte_ether_addr src;
    struct rte_ether_addr dst;
    bool match_src;
    bool match_dst;
    uint8_t pkt_type;
    bool forward;
    bool has_loss;
    bool has_delay;
    bool has_rate;
    double loss_pct;
    uint32_t delay_ms;
    uint32_t rate_mbps;
    uint16_t replica_count;
    struct rte_ether_addr replicas[MAX_REPLICAS];
};

struct app_cfg {
    char ingress_name[64];
    char egress_name[64];
    char rules_path[512];
    uint16_t burst_size;
    uint16_t ingress_port;
    uint16_t egress_port;
    uint32_t dedup_ms;
    bool event_mode;
    bool event_strict;
};

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_reload = 0;

static struct mac_rule g_rules[MAX_RULES];
static uint32_t g_rule_count = 0;
static bool g_default_forward = false;

static uint64_t g_rx = 0;
static uint64_t g_fwd = 0;
static uint64_t g_drop = 0;
static uint64_t g_dup_drop = 0;
static uint64_t g_dbg_unmatched = 0;
static uint64_t g_loss_drop = 0;
static uint64_t g_delay_enq = 0;
static uint64_t g_rate_shaped = 0;
static uint64_t g_q_overflow_drop = 0;
static uint64_t g_replica_empty_drop = 0;
static uint64_t g_bum_fanout_pkts = 0;
static uint64_t g_bum_fanout_replicas = 0;
static uint64_t g_bum_fanout_skip_src = 0;
static uint64_t g_ospf_mc_classified = 0;
static uint64_t g_ospf_mc_rule_fwd_hit = 0;
static uint64_t g_ospf_mc_apply_enter = 0;
static uint64_t g_tx_burst_zero = 0;
static struct rte_ether_addr g_egress_mac;
static struct rte_mempool *g_mp = NULL;
static struct rte_ether_addr g_l2_endpoints[MAX_L2_ENDPOINTS];
static uint16_t g_l2_endpoint_count = 0;
static bool g_bum_fanout_enable = false;

struct dedup_slot {
    uint64_t sig;
    uint64_t tsc;
};

static struct dedup_slot g_dedup[DEDUP_TABLE_SIZE];

struct rate_state {
    double tokens_bits;
    uint64_t last_tsc;
};

struct delayed_pkt {
    struct rte_mbuf *m;
    uint64_t send_tsc;
};

static struct rate_state g_rate_state[MAX_RULES];
static struct delayed_pkt g_delay_q[MAX_DELAY_Q];
static uint32_t g_delay_head = 0;
static uint32_t g_delay_tail = 0;
static uint64_t g_last_sched_tsc = 0;

enum pkt_type_rule {
    PKT_ANY = 0,
    PKT_UNICAST = 1,
    PKT_MULTICAST = 2,
    PKT_ARP_BROADCAST = 3,
    PKT_BROADCAST = 4,
};

static bool delay_q_push(struct rte_mbuf *m, uint64_t send_tsc);
static uint64_t rate_wait_tsc(uint32_t rule_idx, uint32_t pkt_bits, uint64_t now, uint64_t hz);

static uint64_t frame_sig(const struct rte_ether_hdr *eh, uint16_t pkt_len) {
    uint64_t h = 1469598103934665603ULL;
    for (int i = 0; i < 6; i++) {
        h ^= eh->src_addr.addr_bytes[i];
        h *= 1099511628211ULL;
    }
    for (int i = 0; i < 6; i++) {
        h ^= eh->dst_addr.addr_bytes[i];
        h *= 1099511628211ULL;
    }
    h ^= eh->ether_type;
    h *= 1099511628211ULL;
    h ^= pkt_len;
    h *= 1099511628211ULL;
    return h;
}

static bool seen_recent(const struct rte_ether_hdr *eh, uint16_t pkt_len, uint64_t now, uint64_t window_tsc) {
    if (window_tsc == 0) {
        return false;
    }
    uint64_t sig = frame_sig(eh, pkt_len);
    uint32_t idx = (uint32_t)(sig & (DEDUP_TABLE_SIZE - 1));
    struct dedup_slot *s = &g_dedup[idx];
    if (s->sig == sig && (now - s->tsc) <= window_tsc) {
        return true;
    }
    s->sig = sig;
    s->tsc = now;
    return false;
}

static void on_signal(int sig) {
    if (sig == SIGHUP) {
        g_reload = 1;
    } else {
        g_stop = 1;
    }
}

static int parse_mac(const char *s, struct rte_ether_addr *mac) {
    unsigned int b[6];
    if (sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
        return -1;
    }
    for (int i = 0; i < 6; i++) {
        mac->addr_bytes[i] = (uint8_t)b[i];
    }
    return 0;
}

static int extract_json_string(const char *obj, const char *key, char *out, size_t out_sz) {
    const char *k = strstr(obj, key);
    if (k == NULL) {
        return -1;
    }
    const char *colon = strchr(k, ':');
    if (colon == NULL) {
        return -1;
    }
    const char *q1 = strchr(colon, '"');
    if (q1 == NULL) {
        return -1;
    }
    const char *q2 = strchr(q1 + 1, '"');
    if (q2 == NULL || q2 <= q1 + 1) {
        return -1;
    }
    size_t n = (size_t)(q2 - (q1 + 1));
    if (n + 1 > out_sz) {
        return -1;
    }
    memcpy(out, q1 + 1, n);
    out[n] = '\0';
    return 0;
}

static int extract_json_number(const char *obj, const char *key, double *out) {
    const char *k = strstr(obj, key);
    if (k == NULL) {
        return -1;
    }
    const char *colon = strchr(k, ':');
    if (colon == NULL) {
        return -1;
    }
    const char *p = colon + 1;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
        p++;
    }
    char *endptr = NULL;
    double v = strtod(p, &endptr);
    if (endptr == p) {
        return -1;
    }
    *out = v;
    return 0;
}

static int extract_json_mac_array(const char *obj,
                                  const char *key,
                                  struct rte_ether_addr *out,
                                  uint16_t *out_count,
                                  uint16_t cap) {
    const char *k = strstr(obj, key);
    if (k == NULL) {
        return -1;
    }
    const char *colon = strchr(k, ':');
    if (colon == NULL) {
        return -1;
    }
    const char *lb = strchr(colon, '[');
    if (lb == NULL) {
        return -1;
    }
    const char *rb = strchr(lb, ']');
    if (rb == NULL || rb <= lb) {
        return -1;
    }
    uint16_t cnt = 0;
    const char *p = lb;
    while (p < rb) {
        const char *q1 = strchr(p, '"');
        if (q1 == NULL || q1 >= rb) {
            break;
        }
        const char *q2 = strchr(q1 + 1, '"');
        if (q2 == NULL || q2 >= rb) {
            break;
        }
        size_t n = (size_t)(q2 - (q1 + 1));
        if (n > 0 && n < 64) {
            char mac_s[64];
            memcpy(mac_s, q1 + 1, n);
            mac_s[n] = '\0';
            if (cnt >= cap || parse_mac(mac_s, &out[cnt]) != 0) {
                return -1;
            }
            cnt++;
        }
        p = q2 + 1;
    }
    *out_count = cnt;
    return 0;
}

static int parse_pkt_type(const char *s, uint8_t *t) {
    if (strcmp(s, "any") == 0) {
        *t = PKT_ANY;
        return 0;
    }
    if (strcmp(s, "unicast") == 0) {
        *t = PKT_UNICAST;
        return 0;
    }
    if (strcmp(s, "multicast") == 0 || strcmp(s, "ospf_multicast") == 0) {
        *t = PKT_MULTICAST;
        return 0;
    }
    if (strcmp(s, "arp_broadcast") == 0) {
        *t = PKT_ARP_BROADCAST;
        return 0;
    }
    if (strcmp(s, "broadcast") == 0) {
        *t = PKT_BROADCAST;
        return 0;
    }
    return -1;
}

static int load_rules(const char *path) {
    FILE *fp = fopen(path, "r");
    if (fp == NULL) {
        fprintf(stderr, "[rules] open failed: %s (%s)\n", path, strerror(errno));
        return -1;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return -1;
    }
    long sz = ftell(fp);
    if (sz < 0) {
        fclose(fp);
        return -1;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return -1;
    }

    char *buf = malloc((size_t)sz + 1);
    if (buf == NULL) {
        fclose(fp);
        return -1;
    }
    size_t nr = fread(buf, 1, (size_t)sz, fp);
    fclose(fp);
    buf[nr] = '\0';

    struct mac_rule tmp[MAX_RULES];
    struct rate_state new_rate_state[MAX_RULES];
    memset(new_rate_state, 0, sizeof(new_rate_state));
    uint32_t cnt = 0;
    bool default_forward = false;
    struct rte_ether_addr new_eps[MAX_L2_ENDPOINTS];
    uint16_t new_ep_count = 0;

    char default_act_s[32];
    if (extract_json_string(buf, "\"default_action\"", default_act_s, sizeof(default_act_s)) == 0) {
        default_forward = (strcmp(default_act_s, "forward") == 0);
    }
    if (extract_json_mac_array(buf, "\"l2_endpoints\"", new_eps, &new_ep_count, MAX_L2_ENDPOINTS) != 0) {
        new_ep_count = 0;
    }

    const char *p = buf;
    while ((p = strchr(p, '{')) != NULL) {
        const char *end = strchr(p, '}');
        if (end == NULL) {
            break;
        }
        size_t n = (size_t)(end - p + 1);
        char *obj = malloc(n + 1);
        if (obj == NULL) {
            free(buf);
            return -1;
        }
        memcpy(obj, p, n);
        obj[n] = '\0';

        char src_s[64], dst_s[64], act_s[32];
        int ok_src = extract_json_string(obj, "\"src_mac\"", src_s, sizeof(src_s));
        int ok_dst = extract_json_string(obj, "\"dst_mac\"", dst_s, sizeof(dst_s));
        int ok_act = extract_json_string(obj, "\"action\"", act_s, sizeof(act_s));
        char type_s[32];
        int ok_type = extract_json_string(obj, "\"pkt_type\"", type_s, sizeof(type_s));
        if (ok_act == 0 && cnt < MAX_RULES) {
            struct mac_rule r;
            memset(&r, 0, sizeof(r));
            if (ok_src == 0) {
                if (parse_mac(src_s, &r.src) != 0) {
                    free(obj);
                    p = end + 1;
                    continue;
                }
                r.match_src = true;
            }
            if (ok_dst == 0) {
                if (parse_mac(dst_s, &r.dst) != 0) {
                    free(obj);
                    p = end + 1;
                    continue;
                }
                r.match_dst = true;
            }
            r.pkt_type = PKT_ANY;
            if (ok_type == 0 && parse_pkt_type(type_s, &r.pkt_type) != 0) {
                free(obj);
                p = end + 1;
                continue;
            }
            if (r.match_src || r.match_dst || r.pkt_type != PKT_ANY) {
                r.forward = (strcmp(act_s, "forward") == 0 || strcmp(act_s, "replicate") == 0);
                uint16_t rep_cnt = 0;
                if (extract_json_mac_array(obj, "\"replicate_dsts\"", r.replicas, &rep_cnt, MAX_REPLICAS) == 0) {
                    r.replica_count = rep_cnt;
                }
                double nval = 0.0;
                if (extract_json_number(obj, "\"loss_pct\"", &nval) == 0) {
                    if (nval < 0.0) {
                        nval = 0.0;
                    }
                    if (nval > 100.0) {
                        nval = 100.0;
                    }
                    r.has_loss = true;
                    r.loss_pct = nval;
                }
                if (extract_json_number(obj, "\"delay_ms\"", &nval) == 0) {
                    if (nval < 0.0) {
                        nval = 0.0;
                    }
                    if (nval > 60000.0) {
                        nval = 60000.0;
                    }
                    r.has_delay = true;
                    r.delay_ms = (uint32_t)nval;
                }
                if (extract_json_number(obj, "\"rate_mbps\"", &nval) == 0) {
                    if (nval < 0.0) {
                        nval = 0.0;
                    }
                    if (nval > 100000.0) {
                        nval = 100000.0;
                    }
                    if (nval > 0.0) {
                        r.has_rate = true;
                        r.rate_mbps = (uint32_t)nval;
                    }
                }
                tmp[cnt++] = r;
            }
        }

        free(obj);
        p = end + 1;
    }

    memcpy(g_rules, tmp, sizeof(struct mac_rule) * cnt);
    memcpy(g_rate_state, new_rate_state, sizeof(new_rate_state));
    memcpy(g_l2_endpoints, new_eps, sizeof(struct rte_ether_addr) * new_ep_count);
    g_l2_endpoint_count = new_ep_count;
    g_rule_count = cnt;
    g_default_forward = default_forward;
    free(buf);
    printf("[rules] loaded=%" PRIu32 " file=%s default=%s l2_endpoints=%" PRIu16 "\n",
           g_rule_count,
           path,
           g_default_forward ? "forward" : "drop",
           g_l2_endpoint_count);
    return 0;
}

static uint8_t classify_pkt_type(const struct rte_ether_hdr *eh) {
    if (rte_is_broadcast_ether_addr(&eh->dst_addr)) {
        if (eh->ether_type == rte_cpu_to_be_16(RTE_ETHER_TYPE_ARP)) {
            return PKT_ARP_BROADCAST;
        }
        return PKT_BROADCAST;
    }
    if (rte_is_multicast_ether_addr(&eh->dst_addr)) {
        return PKT_MULTICAST;
    }
    return PKT_UNICAST;
}

static bool match_rule(const struct rte_ether_addr *src, const struct rte_ether_addr *dst, uint8_t pkt_type, uint32_t *rule_idx, bool *forward) {
    for (uint32_t i = 0; i < g_rule_count; i++) {
        if (g_rules[i].pkt_type != PKT_ANY && g_rules[i].pkt_type != pkt_type) {
            continue;
        }
        if (g_rules[i].match_src && !rte_is_same_ether_addr(src, &g_rules[i].src)) {
            continue;
        }
        if (g_rules[i].match_dst && !rte_is_same_ether_addr(dst, &g_rules[i].dst)) {
            continue;
        }
        *rule_idx = i;
        *forward = g_rules[i].forward;
        return true;
    }
    return false;
}

static bool apply_impairment_or_queue(struct rte_mbuf *m,
                                      uint32_t rule_idx,
                                      uint64_t now,
                                      uint64_t hz,
                                      struct rte_mbuf **tx,
                                      uint16_t *n_tx,
                                      uint16_t burst_cap,
                                      uint16_t egress_port,
                                      bool trace_ospf_mc) {
    if (trace_ospf_mc) {
        g_ospf_mc_apply_enter++;
    }
    if (g_rules[rule_idx].has_loss && g_rules[rule_idx].loss_pct > 0.0) {
        double r = ((double)rand() / (double)RAND_MAX) * 100.0;
        if (r < g_rules[rule_idx].loss_pct) {
            g_loss_drop++;
            g_drop++;
            rte_pktmbuf_free(m);
            return false;
        }
    }

    uint64_t wait_tsc = 0;
    if (g_rules[rule_idx].has_delay && g_rules[rule_idx].delay_ms > 0) {
        wait_tsc += (hz / 1000ULL) * (uint64_t)g_rules[rule_idx].delay_ms;
    }
    wait_tsc += rate_wait_tsc(rule_idx, rte_pktmbuf_pkt_len(m) * 8U, now, hz);

    if (wait_tsc > 0) {
        uint64_t target = now + wait_tsc;
        if (target < g_last_sched_tsc) {
            target = g_last_sched_tsc;
        }
        g_last_sched_tsc = target;
        if (!delay_q_push(m, target)) {
            g_q_overflow_drop++;
            g_drop++;
            rte_pktmbuf_free(m);
            return false;
        }
        g_delay_enq++;
        return false;
    }

    tx[*n_tx] = m;
    (*n_tx)++;
    if (*n_tx >= burst_cap) {
        uint16_t sent = rte_eth_tx_burst(egress_port, 0, tx, *n_tx);
        if (*n_tx > 0 && sent == 0) {
            g_tx_burst_zero++;
        }
        g_fwd += sent;
        for (uint16_t j = sent; j < *n_tx; j++) {
            g_drop++;
            rte_pktmbuf_free(tx[j]);
        }
        *n_tx = 0;
    }
    return true;
}

static void replicate_or_enqueue(struct rte_mbuf *m,
                                 uint32_t rule_idx,
                                 uint64_t now,
                                 uint64_t hz,
                                 struct rte_mbuf **tx,
                                 uint16_t *n_tx,
                                 uint16_t burst_cap,
                                 uint16_t egress_port,
                                 bool trace_ospf_mc) {
    uint16_t rep_cnt = g_rules[rule_idx].replica_count;
    if (rep_cnt == 0) {
        if (g_bum_fanout_enable &&
            g_l2_endpoint_count > 0 &&
            g_rules[rule_idx].pkt_type != PKT_UNICAST &&
            !g_rules[rule_idx].match_dst) {
            struct rte_ether_hdr *src_eh = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
            uint16_t targets = 0;
            for (uint16_t i = 0; i < g_l2_endpoint_count; i++) {
                if (rte_is_same_ether_addr(&src_eh->src_addr, &g_l2_endpoints[i])) {
                    g_bum_fanout_skip_src++;
                    continue;
                }
                targets++;
            }
            if (targets > 0) {
                uint16_t emitted = 0;
                g_bum_fanout_pkts++;
                for (uint16_t i = 0; i < g_l2_endpoint_count; i++) {
                    if (rte_is_same_ether_addr(&src_eh->src_addr, &g_l2_endpoints[i])) {
                        continue;
                    }
                    struct rte_mbuf *out_m = NULL;
                    if (emitted + 1U == targets) {
                        out_m = m;
                    } else {
                        out_m = rte_pktmbuf_clone(m, g_mp);
                        if (out_m == NULL) {
                            g_drop++;
                            continue;
                        }
                    }
                    struct rte_ether_hdr *out_eh = rte_pktmbuf_mtod(out_m, struct rte_ether_hdr *);
                    rte_ether_addr_copy(&g_l2_endpoints[i], &out_eh->dst_addr);
                    g_bum_fanout_replicas++;
                    apply_impairment_or_queue(out_m, rule_idx, now, hz, tx, n_tx, burst_cap, egress_port, trace_ospf_mc);
                    emitted++;
                }
                return;
            }
        }
        /* Compatibility fallback when no endpoints/fanout targets are available. */
        g_replica_empty_drop++;
        apply_impairment_or_queue(m, rule_idx, now, hz, tx, n_tx, burst_cap, egress_port, trace_ospf_mc);
        return;
    }

    for (uint16_t i = 0; i < rep_cnt; i++) {
        struct rte_mbuf *out_m = NULL;
        if (i + 1U == rep_cnt) {
            out_m = m;
        } else {
            out_m = rte_pktmbuf_clone(m, g_mp);
            if (out_m == NULL) {
                g_drop++;
                continue;
            }
        }
        struct rte_ether_hdr *out_eh = rte_pktmbuf_mtod(out_m, struct rte_ether_hdr *);
        rte_ether_addr_copy(&g_rules[rule_idx].replicas[i], &out_eh->dst_addr);
        apply_impairment_or_queue(out_m, rule_idx, now, hz, tx, n_tx, burst_cap, egress_port, trace_ospf_mc);
    }
}

static bool delay_q_empty(void) {
    return g_delay_head == g_delay_tail;
}

static bool delay_q_full(void) {
    return ((g_delay_tail + 1U) % MAX_DELAY_Q) == g_delay_head;
}

static bool delay_q_push(struct rte_mbuf *m, uint64_t send_tsc) {
    if (delay_q_full()) {
        return false;
    }
    g_delay_q[g_delay_tail].m = m;
    g_delay_q[g_delay_tail].send_tsc = send_tsc;
    g_delay_tail = (g_delay_tail + 1U) % MAX_DELAY_Q;
    return true;
}

static void flush_delay_queue(uint16_t egress_port, uint16_t burst, uint64_t now) {
        struct rte_mbuf *tx[DEFAULT_BURST];
    uint16_t n_tx = 0;
    while (!delay_q_empty() && n_tx < burst) {
        struct delayed_pkt *dp = &g_delay_q[g_delay_head];
        if (dp->send_tsc > now) {
            break;
        }
        tx[n_tx++] = dp->m;
        g_delay_head = (g_delay_head + 1U) % MAX_DELAY_Q;
    }
    if (n_tx == 0) {
        return;
    }
    uint16_t sent = rte_eth_tx_burst(egress_port, 0, tx, n_tx);
    g_fwd += sent;
    for (uint16_t i = sent; i < n_tx; i++) {
        g_drop++;
        rte_pktmbuf_free(tx[i]);
    }
}

static uint64_t rate_wait_tsc(uint32_t rule_idx, uint32_t pkt_bits, uint64_t now, uint64_t hz) {
    if (rule_idx >= g_rule_count || !g_rules[rule_idx].has_rate || g_rules[rule_idx].rate_mbps == 0) {
        return 0;
    }
    struct rate_state *rs = &g_rate_state[rule_idx];
    if (rs->last_tsc == 0) {
        rs->last_tsc = now;
        rs->tokens_bits = (double)pkt_bits;
    }
    double rate_bps = (double)g_rules[rule_idx].rate_mbps * 1000000.0;
    double dt = (double)(now - rs->last_tsc) / (double)hz;
    rs->last_tsc = now;
    rs->tokens_bits += dt * rate_bps;
    {
        double cap = rate_bps * 0.1;  // 100ms burst
        if (rs->tokens_bits > cap) {
            rs->tokens_bits = cap;
        }
    }
    if (rs->tokens_bits >= (double)pkt_bits) {
        rs->tokens_bits -= (double)pkt_bits;
        return 0;
    }
    {
        double deficit = (double)pkt_bits - rs->tokens_bits;
        rs->tokens_bits = 0.0;
        if (rate_bps <= 0.0) {
            return 0;
        }
        g_rate_shaped++;
        return (uint64_t)((deficit / rate_bps) * (double)hz);
    }
}

static void print_mac(const struct rte_ether_addr *mac, char *out, size_t n) {
    snprintf(out,
             n,
             "%02x:%02x:%02x:%02x:%02x:%02x",
             mac->addr_bytes[0],
             mac->addr_bytes[1],
             mac->addr_bytes[2],
             mac->addr_bytes[3],
             mac->addr_bytes[4],
             mac->addr_bytes[5]);
}

static int resolve_port(const char *name, uint16_t *pid) {
    uint16_t p;
    RTE_ETH_FOREACH_DEV(p) {
        char n[64] = {0};
        if (rte_eth_dev_get_name_by_port(p, n) == 0 && strcmp(n, name) == 0) {
            *pid = p;
            return 0;
        }
    }
    return -1;
}

static void dump_ports(void) {
    uint16_t p;
    uint16_t n = rte_eth_dev_count_avail();
    printf("[ports] available=%u\n", n);
    RTE_ETH_FOREACH_DEV(p) {
        char name[64] = {0};
        if (rte_eth_dev_get_name_by_port(p, name) == 0) {
            printf("[ports] id=%u name=%s\n", p, name);
        } else {
            printf("[ports] id=%u name=<unknown>\n", p);
        }
    }
}

static int setup_port(uint16_t port, struct rte_mempool *mp) {
    struct rte_eth_conf conf;
    memset(&conf, 0, sizeof(conf));

    int rc = rte_eth_dev_configure(port, 1, 1, &conf);
    if (rc < 0) {
        return rc;
    }
    rc = rte_eth_rx_queue_setup(port, 0, RX_RING_SIZE, rte_eth_dev_socket_id(port), NULL, mp);
    if (rc < 0) {
        return rc;
    }
    rc = rte_eth_tx_queue_setup(port, 0, TX_RING_SIZE, rte_eth_dev_socket_id(port), NULL);
    if (rc < 0) {
        return rc;
    }
    rc = rte_eth_dev_start(port);
    if (rc < 0) {
        return rc;
    }
    rte_eth_promiscuous_enable(port);
    return 0;
}

static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [EAL opts] -- --ingress <dpdk_port_name> --egress <dpdk_port_name> --rules <rules.json> [--burst N] [--dedup-ms N] [--mode poll|event] [--event-strict]\n",
            prog);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    struct app_cfg cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.burst_size = DEFAULT_BURST;
    cfg.dedup_ms = 0;
    cfg.event_mode = false;
    cfg.event_strict = false;

    int eal_argc = rte_eal_init(argc, argv);
    if (eal_argc < 0) {
        rte_panic("EAL init failed\n");
    }

    argc -= eal_argc;
    argv += eal_argc;

    static struct option opts[] = {
        {"ingress", required_argument, NULL, 'i'},
        {"egress", required_argument, NULL, 'e'},
        {"rules", required_argument, NULL, 'r'},
        {"burst", required_argument, NULL, 'b'},
        {"dedup-ms", required_argument, NULL, 'd'},
        {"mode", required_argument, NULL, 'm'},
        {"event-strict", no_argument, NULL, 's'},
        {0, 0, 0, 0},
    };

    int c;
    while ((c = getopt_long(argc, argv, "i:e:r:b:d:m:s", opts, NULL)) != -1) {
        switch (c) {
            case 'i':
                snprintf(cfg.ingress_name, sizeof(cfg.ingress_name), "%s", optarg);
                break;
            case 'e':
                snprintf(cfg.egress_name, sizeof(cfg.egress_name), "%s", optarg);
                break;
            case 'r':
                snprintf(cfg.rules_path, sizeof(cfg.rules_path), "%s", optarg);
                break;
            case 'b':
                cfg.burst_size = (uint16_t)atoi(optarg);
                if (cfg.burst_size == 0 || cfg.burst_size > DEFAULT_BURST) {
                    cfg.burst_size = DEFAULT_BURST;
                }
                break;
            case 'd':
                cfg.dedup_ms = (uint32_t)atoi(optarg);
                break;
            case 'm':
                if (strcmp(optarg, "event") == 0) {
                    cfg.event_mode = true;
                } else if (strcmp(optarg, "poll") == 0) {
                    cfg.event_mode = false;
                } else {
                    fprintf(stderr, "invalid --mode: %s\n", optarg);
                    return 2;
                }
                break;
            case 's':
                cfg.event_strict = true;
                break;
            default:
                usage("dpu-dualport-l2");
                return 2;
        }
    }

    if (cfg.ingress_name[0] == '\0' || cfg.egress_name[0] == '\0' || cfg.rules_path[0] == '\0') {
        usage("dpu-dualport-l2");
        return 2;
    }

    if (resolve_port(cfg.ingress_name, &cfg.ingress_port) != 0) {
        fprintf(stderr, "ingress not found: %s\n", cfg.ingress_name);
        dump_ports();
        return 1;
    }
    if (resolve_port(cfg.egress_name, &cfg.egress_port) != 0) {
        fprintf(stderr, "egress not found: %s\n", cfg.egress_name);
        dump_ports();
        return 1;
    }
    struct rte_mempool *mp = rte_pktmbuf_pool_create(
        "MBUF_POOL", NUM_MBUFS, MBUF_CACHE_SIZE, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
    if (mp == NULL) {
        fprintf(stderr, "mbuf pool create failed: %s\n", rte_strerror(rte_errno));
        return 1;
    }

    if (cfg.ingress_port == cfg.egress_port) {
    if (setup_port(cfg.ingress_port, mp) < 0) {
            fprintf(stderr, "port setup failed (single-port mode)\n");
            return 1;
        }
    } else {
        if (setup_port(cfg.ingress_port, mp) < 0 || setup_port(cfg.egress_port, mp) < 0) {
            fprintf(stderr, "port setup failed\n");
            return 1;
        }
    }
    if (rte_eth_macaddr_get(cfg.egress_port, &g_egress_mac) != 0) {
        fprintf(stderr, "get egress mac failed\n");
        return 1;
    }
    g_mp = mp;

    {
        const char *fanout_env = getenv("BUM_FANOUT_ENABLE");
        if (fanout_env != NULL &&
            (strcmp(fanout_env, "1") == 0 ||
             strcasecmp(fanout_env, "true") == 0 ||
             strcasecmp(fanout_env, "yes") == 0 ||
             strcasecmp(fanout_env, "on") == 0)) {
            g_bum_fanout_enable = true;
        }
    }

    if (load_rules(cfg.rules_path) != 0) {
        fprintf(stderr, "rules load failed\n");
        return 1;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    printf("[start] in=%s(%u) out=%s(%u) rules=%s mode=%s event_strict=%s bum_fanout=%s\n",
           cfg.ingress_name,
           cfg.ingress_port,
           cfg.egress_name,
           cfg.egress_port,
           cfg.rules_path,
           cfg.event_mode ? "event" : "poll",
           cfg.event_strict ? "on" : "off",
           g_bum_fanout_enable ? "on" : "off");

    struct rte_mbuf *rx[DEFAULT_BURST];
    struct rte_mbuf *tx[DEFAULT_BURST];
    struct rte_event ev[DEFAULT_BURST];
    uint64_t hz = rte_get_timer_hz();
    uint64_t dedup_window = (hz / 1000) * cfg.dedup_ms;
    uint64_t last = rte_get_timer_cycles();
    srand((unsigned)last);
    if (cfg.event_mode) {
        uint8_t evdev_id = 0;
        uint8_t evport_id = 0;
        uint8_t evqueue_id = 0;
        uint8_t adapter_id = 0;
        int ev_count = rte_event_dev_count();
        if (ev_count == 0) {
            fprintf(stderr, "[event] no eventdev available\n");
            if (cfg.event_strict) {
                return 1;
            }
            cfg.event_mode = false;
            printf("[event] fallback to poll mode\n");
        }

        if (cfg.event_mode) {
            struct rte_event_dev_info info;
            memset(&info, 0, sizeof(info));
            if (rte_event_dev_info_get(evdev_id, &info) < 0) {
                fprintf(stderr, "[event] dev info get failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            }
        }

        if (cfg.event_mode) {
            struct rte_event_dev_config dev_conf;
            memset(&dev_conf, 0, sizeof(dev_conf));
            dev_conf.nb_event_queues = 1;
            dev_conf.nb_event_ports = 1;
            dev_conf.nb_event_queue_flows = 1024;
            dev_conf.nb_event_port_dequeue_depth = cfg.burst_size;
            dev_conf.nb_event_port_enqueue_depth = cfg.burst_size;
            dev_conf.nb_events_limit = 4096;
            if (rte_event_dev_configure(evdev_id, &dev_conf) < 0) {
                fprintf(stderr, "[event] dev configure failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            }
        }

        if (cfg.event_mode) {
            struct rte_event_queue_conf qconf;
            memset(&qconf, 0, sizeof(qconf));
            qconf.nb_atomic_flows = 1024;
            qconf.nb_atomic_order_sequences = 1024;
            qconf.priority = RTE_EVENT_DEV_PRIORITY_NORMAL;
            qconf.schedule_type = RTE_SCHED_TYPE_ATOMIC;
            if (rte_event_queue_setup(evdev_id, evqueue_id, &qconf) < 0) {
                fprintf(stderr, "[event] queue setup failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            }
        }

        if (cfg.event_mode) {
            struct rte_event_port_conf pconf;
            memset(&pconf, 0, sizeof(pconf));
            pconf.dequeue_depth = cfg.burst_size;
            pconf.enqueue_depth = cfg.burst_size;
            pconf.new_event_threshold = 4096;
            if (rte_event_port_setup(evdev_id, evport_id, &pconf) < 0) {
                fprintf(stderr, "[event] port setup failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            }
        }

        if (cfg.event_mode) {
            if (rte_event_port_link(evdev_id, evport_id, &evqueue_id, NULL, 1) != 1) {
                fprintf(stderr, "[event] port link failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            }
        }

        if (cfg.event_mode) {
            if (rte_event_eth_rx_adapter_create(adapter_id, evdev_id, &((struct rte_event_port_conf){
                    .new_event_threshold = 4096,
                    .dequeue_depth = cfg.burst_size,
                    .enqueue_depth = cfg.burst_size
                })) < 0) {
                fprintf(stderr, "[event] rx adapter create failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            }
        }

        if (cfg.event_mode) {
            struct rte_event_eth_rx_adapter_queue_conf aq;
            memset(&aq, 0, sizeof(aq));
            aq.ev.queue_id = evqueue_id;
            aq.ev.sched_type = RTE_SCHED_TYPE_ATOMIC;
            aq.ev.priority = RTE_EVENT_DEV_PRIORITY_NORMAL;
            if (rte_event_eth_rx_adapter_queue_add(adapter_id, cfg.ingress_port, 0, &aq) < 0) {
                fprintf(stderr, "[event] rx adapter queue add failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            }
        }

        if (cfg.event_mode) {
            if (rte_event_dev_start(evdev_id) < 0 || rte_event_eth_rx_adapter_start(adapter_id) < 0) {
                fprintf(stderr, "[event] start failed\n");
                if (cfg.event_strict) {
                    return 1;
                }
                cfg.event_mode = false;
                printf("[event] fallback to poll mode\n");
            } else {
                printf("[event] active evdev=%u adapter=%u\n", evdev_id, adapter_id);
            }
        }

        while (!g_stop && cfg.event_mode) {
            if (unlikely(g_reload)) {
                g_reload = 0;
                if (load_rules(cfg.rules_path) != 0) {
                    fprintf(stderr, "[rules] reload failed, keeping previous rules\n");
                }
            }
            uint64_t now = rte_get_timer_cycles();
            flush_delay_queue(cfg.egress_port, cfg.burst_size, now);

            uint16_t nb_rx = rte_event_dequeue_burst(evdev_id, evport_id, ev, cfg.burst_size, 0);
            if (nb_rx == 0) {
                continue;
            }
            g_rx += nb_rx;

            uint16_t n_tx = 0;
            now = rte_get_timer_cycles();
            for (uint16_t i = 0; i < nb_rx; i++) {
                struct rte_mbuf *m = ev[i].mbuf;
                struct rte_ether_hdr *eh = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
                if (seen_recent(eh, rte_pktmbuf_pkt_len(m), now, dedup_window)) {
                    g_dup_drop++;
                    g_drop++;
                    rte_pktmbuf_free(m);
                    continue;
                }
                uint8_t pkt_type = classify_pkt_type(eh);
                bool is_ospf_mc = (pkt_type == PKT_MULTICAST);
                if (is_ospf_mc) {
                    g_ospf_mc_classified++;
                }
                uint32_t rule_idx = 0;
                bool forward = false;
                bool has_rule = match_rule(&eh->src_addr, &eh->dst_addr, pkt_type, &rule_idx, &forward);
                if (is_ospf_mc && has_rule && forward) {
                    g_ospf_mc_rule_fwd_hit++;
                }
                if (!has_rule) {
                    forward = g_default_forward;
                }
                if (!forward) {
                    if (g_dbg_unmatched < 20) {
                        char s[32], d[32];
                        print_mac(&eh->src_addr, s, sizeof(s));
                        print_mac(&eh->dst_addr, d, sizeof(d));
                        printf("[debug-unmatched] src=%s dst=%s\\n", s, d);
                        g_dbg_unmatched++;
                    }
                    g_drop++;
                    rte_pktmbuf_free(m);
                    continue;
                }
                if (has_rule) {
                    if (g_rules[rule_idx].replica_count > 0 ||
                        (g_rules[rule_idx].pkt_type != PKT_UNICAST && !g_rules[rule_idx].match_dst)) {
                        replicate_or_enqueue(m, rule_idx, now, hz, tx, &n_tx, cfg.burst_size, cfg.egress_port, is_ospf_mc);
                    } else {
                        apply_impairment_or_queue(m, rule_idx, now, hz, tx, &n_tx, cfg.burst_size, cfg.egress_port, is_ospf_mc);
                    }
                } else {
                    tx[n_tx] = m;
                    n_tx++;
                    if (n_tx >= cfg.burst_size) {
                        uint16_t sent = rte_eth_tx_burst(cfg.egress_port, 0, tx, n_tx);
                        if (n_tx > 0 && sent == 0) {
                            g_tx_burst_zero++;
                        }
                        g_fwd += sent;
                        for (uint16_t j = sent; j < n_tx; j++) {
                            g_drop++;
                            rte_pktmbuf_free(tx[j]);
                        }
                        n_tx = 0;
                    }
                }
            }

            if (n_tx > 0) {
                uint16_t sent = rte_eth_tx_burst(cfg.egress_port, 0, tx, n_tx);
                if (n_tx > 0 && sent == 0) {
                    g_tx_burst_zero++;
                }
                g_fwd += sent;
                for (uint16_t i = sent; i < n_tx; i++) {
                    g_drop++;
                    rte_pktmbuf_free(tx[i]);
                }
            }

            now = rte_get_timer_cycles();
            if (unlikely(now - last > hz)) {
                printf("[stat] rx=%" PRIu64 " fwd=%" PRIu64 " drop=%" PRIu64 " dup_drop=%" PRIu64 " loss_drop=%" PRIu64 " delay_enq=%" PRIu64 " rate_shaped=%" PRIu64 " q_overflow=%" PRIu64 " replica_empty_drop=%" PRIu64 " bum_fanout_pkts=%" PRIu64 " bum_fanout_replicas=%" PRIu64 " bum_skip_src=%" PRIu64 " ospf_cls=%" PRIu64 " ospf_rule_fwd=%" PRIu64 " ospf_apply=%" PRIu64 " tx_zero=%" PRIu64 " rules=%" PRIu32 "\n",
                       g_rx,
                       g_fwd,
                       g_drop,
                       g_dup_drop,
                       g_loss_drop,
                       g_delay_enq,
                       g_rate_shaped,
                       g_q_overflow_drop,
                       g_replica_empty_drop,
                       g_bum_fanout_pkts,
                       g_bum_fanout_replicas,
                       g_bum_fanout_skip_src,
                       g_ospf_mc_classified,
                       g_ospf_mc_rule_fwd_hit,
                       g_ospf_mc_apply_enter,
                       g_tx_burst_zero,
                       g_rule_count);
                last = now;
            }
        }
        if (cfg.event_mode) {
            rte_event_eth_rx_adapter_stop(adapter_id);
            rte_event_eth_rx_adapter_queue_del(adapter_id, cfg.ingress_port, 0);
            rte_event_eth_rx_adapter_free(adapter_id);
            rte_event_dev_stop(evdev_id);
            rte_event_dev_close(evdev_id);
        }
    }

    while (!g_stop && !cfg.event_mode) {
        if (unlikely(g_reload)) {
            g_reload = 0;
            if (load_rules(cfg.rules_path) != 0) {
                fprintf(stderr, "[rules] reload failed, keeping previous rules\n");
            }
        }

        uint64_t now = rte_get_timer_cycles();
        flush_delay_queue(cfg.egress_port, cfg.burst_size, now);

        uint16_t nb_rx = rte_eth_rx_burst(cfg.ingress_port, 0, rx, cfg.burst_size);
        if (nb_rx == 0) {
            continue;
        }

        g_rx += nb_rx;
        uint16_t n_tx = 0;
        now = rte_get_timer_cycles();
        for (uint16_t i = 0; i < nb_rx; i++) {
            struct rte_mbuf *m = rx[i];
            struct rte_ether_hdr *eh = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
            if (seen_recent(eh, rte_pktmbuf_pkt_len(m), now, dedup_window)) {
                g_dup_drop++;
                g_drop++;
                rte_pktmbuf_free(m);
                continue;
            }
            uint8_t pkt_type = classify_pkt_type(eh);
            bool is_ospf_mc = (pkt_type == PKT_MULTICAST);
            if (is_ospf_mc) {
                g_ospf_mc_classified++;
            }
            uint32_t rule_idx = 0;
            bool forward = false;
            bool has_rule = match_rule(&eh->src_addr, &eh->dst_addr, pkt_type, &rule_idx, &forward);
            if (is_ospf_mc && has_rule && forward) {
                g_ospf_mc_rule_fwd_hit++;
            }
            if (!has_rule) {
                forward = g_default_forward;
            }
            if (!forward) {
                if (g_dbg_unmatched < 20) {
                    char s[32], d[32];
                    print_mac(&eh->src_addr, s, sizeof(s));
                    print_mac(&eh->dst_addr, d, sizeof(d));
                    printf("[debug-unmatched] src=%s dst=%s\\n", s, d);
                    g_dbg_unmatched++;
                }
                g_drop++;
                rte_pktmbuf_free(m);
                continue;
            }

            if (has_rule) {
                if (g_rules[rule_idx].replica_count > 0 ||
                    (g_rules[rule_idx].pkt_type != PKT_UNICAST && !g_rules[rule_idx].match_dst)) {
                    replicate_or_enqueue(m, rule_idx, now, hz, tx, &n_tx, cfg.burst_size, cfg.egress_port, is_ospf_mc);
                } else {
                    apply_impairment_or_queue(m, rule_idx, now, hz, tx, &n_tx, cfg.burst_size, cfg.egress_port, is_ospf_mc);
                }
            } else {
                tx[n_tx] = m;
                n_tx++;
                if (n_tx >= cfg.burst_size) {
                    uint16_t sent = rte_eth_tx_burst(cfg.egress_port, 0, tx, n_tx);
                    if (n_tx > 0 && sent == 0) {
                        g_tx_burst_zero++;
                    }
                    g_fwd += sent;
                    for (uint16_t j = sent; j < n_tx; j++) {
                        g_drop++;
                        rte_pktmbuf_free(tx[j]);
                    }
                    n_tx = 0;
                }
            }
        }

        if (n_tx > 0) {
            uint16_t sent = rte_eth_tx_burst(cfg.egress_port, 0, tx, n_tx);
            if (n_tx > 0 && sent == 0) {
                g_tx_burst_zero++;
            }
            g_fwd += sent;
            for (uint16_t i = sent; i < n_tx; i++) {
                g_drop++;
                rte_pktmbuf_free(tx[i]);
            }
        }

        now = rte_get_timer_cycles();
        if (unlikely(now - last > hz)) {
            printf("[stat] rx=%" PRIu64 " fwd=%" PRIu64 " drop=%" PRIu64 " dup_drop=%" PRIu64 " loss_drop=%" PRIu64 " delay_enq=%" PRIu64 " rate_shaped=%" PRIu64 " q_overflow=%" PRIu64 " replica_empty_drop=%" PRIu64 " bum_fanout_pkts=%" PRIu64 " bum_fanout_replicas=%" PRIu64 " bum_skip_src=%" PRIu64 " ospf_cls=%" PRIu64 " ospf_rule_fwd=%" PRIu64 " ospf_apply=%" PRIu64 " tx_zero=%" PRIu64 " rules=%" PRIu32 "\n",
                   g_rx,
                   g_fwd,
                   g_drop,
                   g_dup_drop,
                   g_loss_drop,
                   g_delay_enq,
                   g_rate_shaped,
                   g_q_overflow_drop,
                   g_replica_empty_drop,
                   g_bum_fanout_pkts,
                   g_bum_fanout_replicas,
                   g_bum_fanout_skip_src,
                   g_ospf_mc_classified,
                   g_ospf_mc_rule_fwd_hit,
                   g_ospf_mc_apply_enter,
                   g_tx_burst_zero,
                   g_rule_count);
            last = now;
        }
    }

    rte_eth_dev_stop(cfg.ingress_port);
    rte_eth_dev_close(cfg.ingress_port);
    if (cfg.egress_port != cfg.ingress_port) {
        rte_eth_dev_stop(cfg.egress_port);
        rte_eth_dev_close(cfg.egress_port);
    }

    printf("[stop] rx=%" PRIu64 " fwd=%" PRIu64 " drop=%" PRIu64 "\n", g_rx, g_fwd, g_drop);
    return 0;
}

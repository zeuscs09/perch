#include "ct_agent.h"

#include "layout.h"

// ทั้งสามเฉดต้องมาเป็นชุด — เปลี่ยนแค่สีลำตัวโดยทิ้งเงาเป็นสีดินเดิมจะได้มาสคอต
// ที่ดูเหมือนถูกทาสีทับ ไม่ใช่ตัวละครคนละตัว
typedef struct {
    uint16_t body;
    uint16_t dark;
    uint16_t sleep;
} agent_palette_t;

static const agent_palette_t PALETTES[CT_AGENT_COUNT] = {
    [CT_AGENT_CLAUDE] = {CT_COL_CLAY, CT_COL_CLAY_DARK, CT_COL_CLAY_SLEEP},
    [CT_AGENT_CODEX] = {CT_COL_CODEX, CT_COL_CODEX_DARK, CT_COL_CODEX_SLEEP},
    [CT_AGENT_ANTIGRAVITY] = {CT_COL_ANTIGRAV, CT_COL_ANTIGRAV_DARK, CT_COL_ANTIGRAV_SLEEP},
};

static const char *const LABELS[CT_AGENT_COUNT] = {
    [CT_AGENT_CLAUDE] = "Claude",
    [CT_AGENT_CODEX] = "Codex",
    [CT_AGENT_ANTIGRAVITY] = "AG",
};

void ct_agent_recolor(ct_rects_t *rs, ct_agent_t agent)
{
    if (agent <= CT_AGENT_CLAUDE || agent >= CT_AGENT_COUNT) return;
    const agent_palette_t *p = &PALETTES[agent];
    for (int i = 0; i < rs->count; i++) {
        uint16_t c = rs->items[i].color;
        // เทียบกับสีต้นฉบับตรงๆ ไม่ใช่เดาจากความสว่าง — asset เป็นจานสีปิด
        // สีที่ไม่อยู่ในสามเฉดนี้คือของชิ้นอื่นที่ต้องคงเดิม
        if (c == CT_COL_CLAY) {
            rs->items[i].color = p->body;
        } else if (c == CT_COL_CLAY_DARK) {
            rs->items[i].color = p->dark;
        } else if (c == CT_COL_CLAY_SLEEP) {
            rs->items[i].color = p->sleep;
        }
    }
}

const char *ct_agent_label(ct_agent_t agent)
{
    if (agent < 0 || agent >= CT_AGENT_COUNT) return LABELS[CT_AGENT_CLAUDE];
    return LABELS[agent];
}

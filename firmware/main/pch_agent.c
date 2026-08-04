#include "pch_agent.h"

#include "layout.h"

// ทั้งสามเฉดต้องมาเป็นชุด — เปลี่ยนแค่สีลำตัวโดยทิ้งเงาเป็นสีดินเดิมจะได้มาสคอต
// ที่ดูเหมือนถูกทาสีทับ ไม่ใช่ตัวละครคนละตัว
typedef struct {
    uint16_t body;
    uint16_t dark;
    uint16_t sleep;
} agent_palette_t;

static const agent_palette_t PALETTES[PCH_AGENT_COUNT] = {
    [PCH_AGENT_CLAUDE] = {PCH_COL_CLAY, PCH_COL_CLAY_DARK, PCH_COL_CLAY_SLEEP},
    [PCH_AGENT_CODEX] = {PCH_COL_CODEX, PCH_COL_CODEX_DARK, PCH_COL_CODEX_SLEEP},
    [PCH_AGENT_ANTIGRAVITY] = {PCH_COL_ANTIGRAV, PCH_COL_ANTIGRAV_DARK, PCH_COL_ANTIGRAV_SLEEP},
};

static const char *const LABELS[PCH_AGENT_COUNT] = {
    [PCH_AGENT_CLAUDE] = "Claude",
    [PCH_AGENT_CODEX] = "Codex",
    [PCH_AGENT_ANTIGRAVITY] = "AG",
};

void pch_agent_recolor(pch_rects_t *rs, pch_agent_t agent)
{
    if (agent <= PCH_AGENT_CLAUDE || agent >= PCH_AGENT_COUNT) return;
    const agent_palette_t *p = &PALETTES[agent];
    for (int i = 0; i < rs->count; i++) {
        uint16_t c = rs->items[i].color;
        // เทียบกับสีต้นฉบับตรงๆ ไม่ใช่เดาจากความสว่าง — asset เป็นจานสีปิด
        // สีที่ไม่อยู่ในสามเฉดนี้คือของชิ้นอื่นที่ต้องคงเดิม
        if (c == PCH_COL_CLAY) {
            rs->items[i].color = p->body;
        } else if (c == PCH_COL_CLAY_DARK) {
            rs->items[i].color = p->dark;
        } else if (c == PCH_COL_CLAY_SLEEP) {
            rs->items[i].color = p->sleep;
        }
    }
}

const char *pch_agent_label(pch_agent_t agent)
{
    if (agent < 0 || agent >= PCH_AGENT_COUNT) return LABELS[PCH_AGENT_CLAUDE];
    return LABELS[agent];
}

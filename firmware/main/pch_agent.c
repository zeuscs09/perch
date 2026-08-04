#include "pch_agent.h"

static const char *const LABELS[PCH_AGENT_COUNT] = {
    [PCH_AGENT_CLAUDE] = "Claude",
    [PCH_AGENT_CODEX] = "Codex",
    [PCH_AGENT_ANTIGRAVITY] = "AG",
};

const char *pch_agent_label(pch_agent_t agent)
{
    if (agent < 0 || agent >= PCH_AGENT_COUNT) return LABELS[PCH_AGENT_CLAUDE];
    return LABELS[agent];
}

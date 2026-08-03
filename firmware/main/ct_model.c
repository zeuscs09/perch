#include "ct_model.h"

#include <string.h>

#include "cJSON.h"
#include "esp_log.h"

static const char *TAG = "model";

static void copy_str(char *dst, size_t cap, const cJSON *item)
{
    dst[0] = '\0';
    if (!cJSON_IsString(item) || !item->valuestring) return;
    strncpy(dst, item->valuestring, cap - 1);
    dst[cap - 1] = '\0';
}

static ct_state_t state_from_name(const char *name)
{
    if (!name) return CT_STATE_IDLE;
    for (int i = 0; i < CT_STATE_COUNT; i++) {
        if (strcmp(name, ct_state_names[i]) == 0) return (ct_state_t)i;
    }
    // ชื่อที่ firmware ไม่รู้จัก = daemon ใหม่กว่า firmware ให้ยืนเฉยๆ ดีกว่าจอค้าง
    ESP_LOGW(TAG, "unknown state '%s'", name);
    return CT_STATE_IDLE;
}

// ตัวอักษรเดียวบนสาย ("c"/"x"/"g") — ต้องตรงกับ AgentKind.wire ฝั่ง host
// ไม่ใช่ตัวแรกของชื่อ: claude กับ codex ขึ้นต้น c เหมือนกัน — ประหยัดไบต์ในงบ MTU ที่แชร์กับ session และ card
// ไม่มีคีย์ = daemon รุ่นก่อนมี multi-agent ซึ่งส่งแต่ session ของ Claude
static ct_agent_t agent_from_name(const char *name)
{
    if (!name) return CT_AGENT_CLAUDE;
    if (name[0] == 'x') return CT_AGENT_CODEX;
    if (name[0] == 'g') return CT_AGENT_ANTIGRAVITY;
    return CT_AGENT_CLAUDE;
}

static ct_card_kind_t kind_from_name(const char *name)
{
    if (!name) return CT_CARD_INFO;
    if (strcmp(name, "alert") == 0) return CT_CARD_ALERT;
    if (strcmp(name, "done") == 0) return CT_CARD_DONE;
    return CT_CARD_INFO;
}

void ct_model_clear(ct_snapshot_t *s)
{
    memset(s, 0, sizeof(*s));
    strcpy(s->clock, "--:--");
    s->temperature = CT_TEMP_UNKNOWN;
    for (int i = 0; i < CT_USAGE_ROWS; i++) {
        s->usage[i].percent = CT_USAGE_UNKNOWN;
        s->usage[i].remaining = CT_USAGE_UNKNOWN;
    }
}

void ct_model_tick_usage(ct_snapshot_t *s, int secs)
{
    if (!s->has_usage) return;
    for (int i = 0; i < CT_USAGE_ROWS; i++) {
        ct_usage_t *u = &s->usage[i];
        if (u->remaining <= 0) continue;
        u->remaining -= secs;
        if (u->remaining > 0) continue;
        // หน้าต่างหมุนไปแล้ว: เปอร์เซ็นต์ที่ถืออยู่ผิดแน่นอนและเราไม่มีทางรู้ค่าใหม่
        // จนกว่า snapshot ถัดไปจะมาถึง ค่าที่ถูกคือ "ไม่รู้" ไม่ใช่ศูนย์
        u->remaining = 0;
        u->percent = CT_USAGE_UNKNOWN;
    }
}

bool ct_model_parse(const char *json, int len, ct_snapshot_t *out)
{
    cJSON *root = cJSON_ParseWithLength(json, len);
    if (!root) return false;

    ct_snapshot_t tmp;
    ct_model_clear(&tmp);

    copy_str(tmp.clock, sizeof(tmp.clock), cJSON_GetObjectItem(root, "c"));
    copy_str(tmp.date, sizeof(tmp.date), cJSON_GetObjectItem(root, "d"));
    const cJSON *overflow = cJSON_GetObjectItem(root, "o");
    if (cJSON_IsNumber(overflow)) tmp.overflow = overflow->valueint;

    const cJSON *sessions = cJSON_GetObjectItem(root, "s");
    if (cJSON_IsArray(sessions)) {
        const cJSON *it = NULL;
        cJSON_ArrayForEach(it, sessions) {
            if (tmp.session_count >= CT_SLOTS_COUNT) break;
            ct_session_t *sess = &tmp.sessions[tmp.session_count++];
            copy_str(sess->project, sizeof(sess->project), cJSON_GetObjectItem(it, "p"));
            const cJSON *st = cJSON_GetObjectItem(it, "s");
            sess->state = state_from_name(cJSON_IsString(st) ? st->valuestring : NULL);
            const cJSON *ag = cJSON_GetObjectItem(it, "a");
            sess->agent = agent_from_name(cJSON_IsString(ag) ? ag->valuestring : NULL);
        }
    }

    const cJSON *cards = cJSON_GetObjectItem(root, "n");
    if (cJSON_IsArray(cards)) {
        const cJSON *it = NULL;
        cJSON_ArrayForEach(it, cards) {
            if (tmp.card_count >= CT_MAX_CARDS) break;
            ct_card_t *card = &tmp.cards[tmp.card_count++];
            copy_str(card->title, sizeof(card->title), cJSON_GetObjectItem(it, "t"));
            copy_str(card->body, sizeof(card->body), cJSON_GetObjectItem(it, "b"));
            const cJSON *k = cJSON_GetObjectItem(it, "k");
            card->kind = kind_from_name(cJSON_IsString(k) ? k->valuestring : NULL);
        }
    }
    const cJSON *card_over = cJSON_GetObjectItem(root, "m");
    if (cJSON_IsNumber(card_over)) tmp.card_overflow = card_over->valueint;

    // "u" เป็น array ของคู่ [percent, วินาทีที่เหลือ] ไม่ใช่ object — คีย์กินไบต์บนสาย
    // ไม่มีคีย์นี้เลย = ยังไม่เคยมีข้อมูลโควตา ซึ่งไม่เหมือนกับ "มีแต่ไม่รู้ค่า"
    const cJSON *usage = cJSON_GetObjectItem(root, "u");
    if (cJSON_IsArray(usage)) {
        int row = 0;
        const cJSON *pair = NULL;
        cJSON_ArrayForEach(pair, usage) {
            if (row >= CT_USAGE_ROWS) break;
            const cJSON *pct = cJSON_GetArrayItem(pair, 0);
            const cJSON *rem = cJSON_GetArrayItem(pair, 1);
            if (cJSON_IsNumber(pct)) tmp.usage[row].percent = pct->valueint;
            if (cJSON_IsNumber(rem)) tmp.usage[row].remaining = rem->valueint;
            row++;
        }
        tmp.has_usage = row > 0;
    }

    // "w" = [condition, องศา C] — array ด้วยเหตุผลเดียวกับ "u" คือคีย์กินไบต์
    const cJSON *w = cJSON_GetObjectItem(root, "w");
    if (cJSON_IsArray(w)) {
        const cJSON *cond = cJSON_GetArrayItem(w, 0);
        const cJSON *temp = cJSON_GetArrayItem(w, 1);
        if (cJSON_IsNumber(cond) && cond->valueint >= 0 && cond->valueint < CT_WEATHER_COUNT) {
            tmp.weather = (ct_weather_t)cond->valueint;
            tmp.has_weather = true;
        }
        if (cJSON_IsNumber(temp)) tmp.temperature = temp->valueint;
    }

    cJSON_Delete(root);
    *out = tmp;  // เขียนทับทีเดียวตอนท้าย — JSON พังกลางทางต้องไม่ทิ้งภาพครึ่งๆ
    return true;
}

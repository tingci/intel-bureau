<script setup lang="ts">
/**
 * 手动出报（MANUAL RUN）：指定单日或日期区间，立刻跑一次，不必等定时任务。
 *
 * 与「定时任务」的区别：定时任务是会重复触发的规则；这里是**一次性**地补出报告。
 * 多天时后端按日期先后串行执行（流水线同一时间只能跑一次），每天单独一份报告。
 * 补历史默认「只预览不投递」，勾掉才是真的往通道推。
 */
import { computed, ref, watch } from 'vue'
import type { ChannelDTO, GroupDTO, Platform } from '@/api/types'
import { api } from '@/api/endpoints'
import { notify } from '@/stores/toast'
import { REAL_PLATFORMS } from '@/utils/meta'
import { zoned, WEEK_CN } from '@/utils/format'
import Modal from '../ui/Modal.vue'
import HudSwitch from '../ui/HudSwitch.vue'
import Icon from '../Icon.vue'

const props = defineProps<{ open: boolean; channels: ChannelDTO[]; groups: GroupDTO[] }>()
const emit = defineEmits<{ close: []; started: [] }>()

/** 本地时区的 YYYY-MM-DD（不能用 toISOString，那是 UTC，会把日期算错一天） */
function localDay(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}
const today = localDay(new Date())
const yesterday = (() => { const d = new Date(); d.setDate(d.getDate() - 1); return localDay(d) })()

const mode = ref<'day' | 'range'>('day')
const day = ref(yesterday)
const from = ref(yesterday)
const to = ref(yesterday)
const platforms = ref<Platform[]>(['wechat'])
const pickGroups = ref(false)
const groupKeys = ref<string[]>([])
const dryRun = ref(true)                      // 默认只预览，不投递
const channelIds = ref<string[]>(props.channels.filter((c) => c.enabled).map((c) => c.id))
const busy = ref(false)

watch(() => props.open, (v) => {
  if (v) { busy.value = false }
})

const wlGroups = computed(() => props.groups.filter((g) => g.whitelisted && platforms.value.includes(g.platform)))

/** 选中的日期清单（与后端同样口径：含首尾，升序） */
const days = computed<string[]>(() => {
  if (mode.value === 'day') return day.value ? [day.value] : []
  if (!from.value || !to.value || to.value < from.value) return []
  const out: string[] = []
  const cur = new Date(`${from.value}T00:00:00`)
  const end = new Date(`${to.value}T00:00:00`)
  let guard = 0
  while (cur <= end && guard < 40) {
    out.push(localDay(cur))
    cur.setDate(cur.getDate() + 1)
    guard++
  }
  return out
})

const tooMany = computed(() => days.value.length > 31)
const weekday = (iso: string): string => {
  const z = zoned(new Date(`${iso}T12:00:00`))
  return z ? WEEK_CN[z.wd] : ''
}

function togglePlat(p: Platform): void {
  platforms.value = platforms.value.includes(p) ? platforms.value.filter((x) => x !== p) : [...platforms.value, p]
  groupKeys.value = groupKeys.value.filter((k) => platforms.value.some((pp) => k.startsWith(pp + ':')))
}
function toggle(list: 'groupKeys' | 'channelIds', v: string): void {
  const arr = list === 'groupKeys' ? groupKeys : channelIds
  arr.value = arr.value.includes(v) ? arr.value.filter((x) => x !== v) : [...arr.value, v]
}

async function start(): Promise<void> {
  if (busy.value) return
  if (!platforms.value.length) { notify.warn('至少选择一个平台'); return }
  if (!days.value.length) { notify.warn('请选择日期', { detail: mode.value === 'range' ? '结束日期不能早于开始日期' : '请先选一天' }); return }
  if (tooMany.value) { notify.warn('一次最多补 31 天', { detail: `当前选了 ${days.value.length} 天` }); return }
  busy.value = true
  try {
    const body = mode.value === 'day'
      ? { date: day.value, platforms: platforms.value }
      : { date_from: from.value, date_to: to.value, platforms: platforms.value }
    const res = await api.manualRun({
      ...body,
      group_keys: pickGroups.value ? groupKeys.value : [],
      channel_ids: dryRun.value ? [] : channelIds.value,
      dry_run: dryRun.value,
    })
    notify.ok(`已开始，共 ${res.total} 天`, {
      detail: res.note + (res.dry_run ? '（只预览，不投递）' : '（会投递到所选通道）'),
    })
    emit('started')
    emit('close')
  } catch { /* toast 已弹出 */ } finally { busy.value = false }
}
</script>

<template>
  <Modal :open="open" title="手动出报" code="MANUAL RUN" :width="620" @close="emit('close')">
    <div class="mr">
      <p class="hint">
        选一天或一段日期立刻出报，不用等定时任务。多天时按日期先后依次执行，<b>每天单独一份报告</b>。
        补历史默认只预览、不投递；每天约需 10~35 分钟（取决于消息量）。
      </p>

      <!-- 单日 / 区间 -->
      <div class="row">
        <span class="lb">日期范围</span>
        <div class="seg">
          <button class="sg" :class="{ on: mode === 'day' }" @click="mode = 'day'">某一天</button>
          <button class="sg" :class="{ on: mode === 'range' }" @click="mode = 'range'">日期区间</button>
        </div>
      </div>

      <div v-if="mode === 'day'" class="row">
        <span class="lb">哪一天</span>
        <input v-model="day" class="input" type="date" :max="today" />
        <span class="tiny">{{ day ? `${day} ${weekday(day)}` : '' }}</span>
      </div>

      <div v-else class="row">
        <span class="lb">从 → 到</span>
        <input v-model="from" class="input" type="date" :max="today" />
        <span class="arrow">→</span>
        <input v-model="to" class="input" type="date" :max="today" />
        <span class="tiny" :class="{ bad: tooMany }">
          {{ days.length }} 天
        </span>
      </div>

      <!-- 选中日期预览 -->
      <div v-if="days.length" class="preview">
        <div class="pl-h">
          <Icon name="calendar" :size="13" />
          <span>将生成 {{ days.length }} 份报告</span>
          <span v-if="dryRun" class="badge violet">只预览</span>
        </div>
        <div class="chips">
          <span v-for="d in days.slice(0, 12)" :key="d" class="chip">
            {{ d.slice(5) }} <i>{{ weekday(d) }}</i>
          </span>
          <span v-if="days.length > 12" class="chip dim">… 还有 {{ days.length - 12 }} 天</span>
        </div>
        <div v-if="tooMany" class="bad">一次最多补 31 天，请缩小范围</div>
      </div>

      <!-- 平台 -->
      <div class="row">
        <span class="lb">平台</span>
        <div class="seg">
          <button v-for="p in REAL_PLATFORMS" :key="p" class="sg" :class="{ on: platforms.includes(p) }"
            @click="togglePlat(p)">{{ p === 'wechat' ? '微信' : p === 'qq' ? 'QQ' : '飞书' }}</button>
        </div>
      </div>

      <!-- 群范围 -->
      <div class="row">
        <span class="lb">群范围</span>
        <HudSwitch v-model="pickGroups" />
        <span class="tiny">{{ pickGroups ? '只跑勾选的群' : '所选平台的全部白名单群' }}</span>
      </div>
      <div v-if="pickGroups" class="groups">
        <label v-for="g in wlGroups" :key="g.key" class="gitem" :class="{ on: groupKeys.includes(g.key) }">
          <input type="checkbox" :checked="groupKeys.includes(g.key)" @change="toggle('groupKeys', g.key)" />
          <span class="gname">{{ g.name }}</span>
        </label>
        <div v-if="!wlGroups.length" class="tiny">该平台还没有白名单群</div>
      </div>

      <!-- 投递 -->
      <div class="row">
        <span class="lb">仅预览</span>
        <HudSwitch v-model="dryRun" />
        <span class="tiny">{{ dryRun ? '不往任何通道推送（推荐）' : '会真的投递到下面的通道' }}</span>
      </div>
      <div v-if="!dryRun" class="row">
        <span class="lb">推送通道</span>
        <div class="seg wrap">
          <button v-for="c in channels" :key="c.id" class="sg" :class="{ on: channelIds.includes(c.id) }"
            @click="toggle('channelIds', c.id)">{{ c.name }}</button>
        </div>
      </div>
      <div v-if="!dryRun && !channelIds.length" class="bad" style="margin-left: 92px">
        还没选通道，这次不会推送到任何地方
      </div>
    </div>

    <template #foot>
      <button class="btn ghost" @click="emit('close')">取消</button>
      <button class="btn primary" :disabled="busy || !days.length || tooMany" @click="start">
        <Icon name="play" :size="14" />{{ busy ? '启动中…' : `开始出报（${days.length} 天）` }}
      </button>
    </template>
  </Modal>
</template>

<style scoped>
.mr { display: flex; flex-direction: column; gap: 12px; }
.hint { margin: 0 0 2px; font-size: 12.5px; line-height: 1.6; color: var(--text-2); }
.hint b { color: var(--text-1); }
.row { display: flex; align-items: center; gap: 10px; min-height: 30px; }
.lb { width: 82px; flex: none; font-size: 12.5px; color: var(--text-2); }
.arrow { color: var(--text-2); }
.tiny { font-size: 11.5px; color: var(--text-2); }
.tiny.bad, .bad { color: var(--red, #ff5d6c); }
.bad { font-size: 11.5px; }
.input[type='date'] { max-width: 168px; }
.seg { display: flex; gap: 6px; }
.seg.wrap { flex-wrap: wrap; }
.sg {
  padding: 5px 12px; font-size: 12.5px; color: var(--text-1);
  background: rgba(34, 228, 255, 0.05); border: 1px solid var(--line);
  border-radius: 2px; cursor: pointer; transition: all 0.15s;
}
.sg:hover { border-color: var(--line-strong); }
.sg.on { color: var(--cyan); border-color: var(--cyan); background: rgba(34, 228, 255, 0.14); }
.preview { padding: 10px 12px; background: rgba(34, 228, 255, 0.05); border: 1px solid var(--line); border-radius: 2px; }
.pl-h { display: flex; align-items: center; gap: 6px; font-size: 12.5px; color: var(--text-1); margin-bottom: 8px; }
.pl-h .badge { margin-left: 4px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip {
  padding: 2px 8px; font-size: 11.5px; font-variant-numeric: tabular-nums;
  color: var(--text-0); background: rgba(34, 228, 255, 0.12);
  border: 1px solid rgba(34, 228, 255, 0.3); border-radius: 2px;
}
.chip i { font-style: normal; color: var(--text-2); margin-left: 3px; }
.chip.dim { background: transparent; border-style: dashed; color: var(--text-2); }
.groups {
  display: flex; flex-wrap: wrap; gap: 6px; margin-left: 92px;
  max-height: 140px; overflow: auto; padding: 6px;
  border: 1px solid var(--line); border-radius: 2px;
}
.gitem {
  display: flex; align-items: center; gap: 5px; padding: 3px 8px;
  font-size: 12px; cursor: pointer; border: 1px solid var(--line); border-radius: 2px;
}
.gitem.on { border-color: var(--cyan); color: var(--cyan); }
.gitem input { accent-color: var(--cyan); }
.gname { max-width: 180px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>

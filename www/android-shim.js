/* 娟光阅影 安卓端运行时垫片：把 Electron 主进程能力替换为浏览器可实现的等价接口 */

const SETTINGS_KEY = 'gy_settings_v1'
const DEFAULT_SETTINGS = {
  theme: 'dark',
  autoplay: true,
  autoplayNext: true,
  prefs: { resume: true, autoplayNext: true },
  lastDirs: [],
  folders: [],
  online: [],
  sources: [
    { name: '暴风资源', api: 'https://bfzyapi.com/api.php/provide/vod', enabled: true },
    { name: '非凡资源', api: 'https://api.ffzyapi.com/api.php/provide/vod', enabled: true },
    { name: '360资源', api: 'https://360zy.com/api.php/provide/vod', enabled: true },
    { name: '电影天堂', api: 'https://caiji.dyttzyapi.com/api.php/provide/vod', enabled: true },
    { name: '新浪资源', api: 'https://api.xinlangapi.com/xinlangapi.php/provide/vod', enabled: true },
    { name: '最大资源', api: 'https://api.zuidapi.com/api.php/provide/vod', enabled: true },
    { name: '无尽资源', api: 'https://api.wujinapi.com/api.php/provide/vod', enabled: true },
    { name: '光速资源', api: 'https://api.guangsuapi.com/api.php/provide/vod', enabled: true },
    { name: '友嗨影院', api: 'https://0av2wu.com', type: 'yh', enabled: true }
  ]
}

function loadSettingsFromStorage() {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY)
    if (raw) {
      const parsed = JSON.parse(raw)
      // 确保包含完整视频源（旧缓存可能只有音乐源或缺失）
      const existing = Array.isArray(parsed.sources) ? parsed.sources : []
      const merged = [...existing]
      for (const def of DEFAULT_SETTINGS.sources) {
        const has = existing.some((s) => s && s.api === def.api)
        if (!has) merged.push({ ...def })
      }
      parsed.sources = merged
      // 旧版本缓存里可能没有 prefs，补上默认值，避免设置页渲染报错
      parsed.prefs = { ...DEFAULT_SETTINGS.prefs, ...(parsed.prefs || {}) }
      return { ...DEFAULT_SETTINGS, ...parsed, sources: merged }
    }
  } catch (_) {}
  return { ...DEFAULT_SETTINGS, sources: DEFAULT_SETTINGS.sources.map((s) => ({ ...s })) }
}

function saveSettingsToStorage(settings) {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings))
  } catch (_) {}
  return settings
}

/* ---------- 网络请求辅助 ---------- */
async function fetchJson(url, headers = {}, timeout = 8000) {
  const ctrl = typeof AbortController === 'function' ? new AbortController() : null
  const timer = ctrl ? setTimeout(() => ctrl.abort(), timeout) : 0
  try {
    const res = await fetch(url, ctrl ? { headers, signal: ctrl.signal } : { headers })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    return await res.json()
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/* ---------- 榜单本地缓存（进音乐厅先渲染缓存，再后台刷新） ---------- */
const CHART_CACHE_PREFIX = 'gy_chart_'

function readChartCache(id) {
  try {
    const raw = localStorage.getItem(CHART_CACHE_PREFIX + id)
    if (!raw) return null
    const data = JSON.parse(raw)
    if (!data || !Array.isArray(data.list) || !data.list.length) return null
    return data
  } catch (_) {
    return null
  }
}

function writeChartCache(id, list) {
  try {
    localStorage.setItem(CHART_CACHE_PREFIX + id, JSON.stringify({ at: Date.now(), list: list.slice(0, 200) }))
  } catch (_) {}
}

/**
 * 走原生 HTTP 插件（GyHttp）发起 GET 请求，返回二进制。
 * WebView 里的 fetch 代理会丢掉 Referer / Origin 等受限请求头，
 * 咪咕接口缺少 Referer 时会直接返回「请求失败」，因此这里用原生请求。
 */
async function nativeGet(url, headers = {}) {
  const cap = window.Capacitor
  if (cap && typeof cap.nativePromise === 'function') {
    const res = await cap.nativePromise('GyHttp', 'get', { url, headers })
    if (res && typeof res.data === 'string') {
      const bin = atob(res.data)
      const bytes = new Uint8Array(bin.length)
      for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i)
      return { status: Number(res.status) || 0, bytes, headers: res.headers || {} }
    }
  }
  const res = await fetch(url, { headers })
  const buf = new Uint8Array(await res.arrayBuffer())
  return { status: res.status, bytes: buf, headers: {} }
}

/** 原生 POST（表单/文本 body），同样返回二进制与响应头 */
async function nativeRequest(method, url, headers = {}, body = '') {
  const cap = window.Capacitor
  if (cap && typeof cap.nativePromise === 'function') {
    const res = await cap.nativePromise('GyHttp', method, { url, headers, body })
    if (!res || typeof res.data !== 'string') return { status: 0, bytes: new Uint8Array(0), headers: {} }
    const bin = atob(res.data)
    const bytes = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i)
    return { status: Number(res.status) || 0, bytes, headers: res.headers || {} }
  }
  const res = await fetch(url, { method: String(method || 'POST').toUpperCase(), headers, body })
  const buf = new Uint8Array(await res.arrayBuffer())
  return { status: res.status, bytes: buf, headers: {} }
}

/**
 * 取 JSON：优先走原生 HTTP（不依赖 WebView 的 fetch 代理，跨域/受限头都更稳），
 * 原生失败或返回非 2xx 时再退回 fetch。
 */
async function nativeJson(url, headers = {}, timeout = 10000) {
  try {
    const { status, bytes } = await nativeGet(url, headers)
    if (status && status < 400 && bytes && bytes.length) {
      return JSON.parse(new TextDecoder('utf8').decode(bytes))
    }
  } catch (_) {}
  return fetchJson(url, headers, timeout)
}

/* ---------- 咪咕解密（浏览器版） ---------- */
const MIGU_KEY = 'Jk8qzuePiJ1qE3mDYhLQ3T73DtDoAhLP'
function miguDecrypt(bytes) {
  if (!bytes || bytes.length < 4) return ''
  if (bytes[0] !== 171 || bytes[1] !== 205 || bytes[2] !== 1) return ''
  const salt = bytes[3]
  const keyBytes = new TextEncoder().encode(MIGU_KEY)
  const out = new Uint8Array(bytes.length - 4)
  for (let i = 4, s = 0; i < bytes.length; i += 1, s += 1) {
    out[s] = (bytes[i] + salt - keyBytes[s % keyBytes.length]) & 0xff
  }
  return new TextDecoder('utf8').decode(out)
}

const MIGU_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  Referer: 'https://music.migu.cn/',
  Origin: 'https://music.migu.cn',
  birth: 'h5page',
  signature: '1',
  'content-type': 'application/json;charset=UTF-8',
  channel: '014X031',
  subchannel: '014X031',
  appId: 'music',
  platform: 'H5'
}

const NETEASE_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  Referer: 'https://music.163.com/',
  Cookie: 'appver=2.0.2'
}

/* ---------- CC 曲库 ---------- */
async function ccMusic(offset = 0) {
  const start = Number(offset) || 0
  const pages = Array.from({ length: 8 }, (_, i) => start + i * 5)
  const results = await Promise.all(
    pages.map((p) =>
      fetchJson(`https://ccmixter.org/api/query?f=json&limit=5&offset=${p}`, {
        'User-Agent': 'Mozilla/5.0',
        Accept: 'application/json'
      }).catch(() => [])
    )
  )
  const seen = new Set()
  const items = []
  for (const list of results) {
    for (const record of Array.isArray(list) ? list : []) {
      if (seen.has(record.upload_id)) continue
      const file = (record.files || []).find((f) => f.download_url && /\.mp3$/i.test(f.download_url))
      if (!file) continue
      seen.add(record.upload_id)
      const scores = Number(record.upload_num_scores || 0) || 0
      items.push({
        id: String(record.upload_id),
        title: String(record.upload_name || '').trim(),
        artist: String(record.user_real_name || record.user_name || '').trim(),
        scores,
        hot: scores,
        duration: (file.file_format_info && file.file_format_info.ps) || '',
        license: String(record.license_name || 'Creative Commons'),
        tags: String(record.upload_tags || ''),
        url: String(file.download_url),
        page: String(record.file_page_url || ''),
        year: (String(record.upload_date_format || '').match(/\d{4}/) || [''])[0]
      })
    }
  }
  return items.filter((item) => item.title && item.url)
}

/* ---------- 网易云 ---------- */
async function neteaseSearch({ keyword, limit }) {
  const kw = String(keyword || '').trim()
  if (!kw) return { list: [] }
  // 搜索每页最多 100 首；/api/search/get 在移动网络下可用，而 /get/web 常返回「操作频繁」，
  // 且并行翻页会被限流，因此这里逐页串行拉取，失败即停止
  const max = Math.max(1, Number(limit) || 200)
  const pageSize = 100
  const seen = new Set()
  const list = []
  let lastError = ''
  try {
    for (let offset = 0; offset < max; offset += pageSize) {
      const size = Math.min(pageSize, max - offset)
      const data = await nativeJson(
        `https://music.163.com/api/search/get?s=${encodeURIComponent(kw)}&type=1&offset=${offset}&limit=${size}`,
        NETEASE_HEADERS,
        10000
      ).catch((err) => {
        lastError = String(err && err.message ? err.message : err)
        return null
      })
      if (!data) break
      if (data.code && data.code !== 200) {
        lastError = String(data.message || data.msg || '')
        break
      }
      const songs = (data.result && data.result.songs) || []
      for (const song of songs) {
        const id = String(song.id || '')
        if (!id || !song.name || seen.has(id)) continue
        const duration = Math.round(Number(song.duration) || 0)
        // 过滤时长不足 1 分钟的片段/试听曲
        if (duration > 0 && duration < 60000) continue
        seen.add(id)
        list.push({
          id,
          title: String(song.name).trim(),
          artist: (song.artists || []).map((e) => (e && e.name) || '').filter(Boolean).join(' / '),
          album: song.album && song.album.name ? String(song.album.name) : '',
          duration
        })
        if (list.length >= max) break
      }
      if (songs.length < size || list.length >= max) break
    }
    if (!list.length && lastError) return { error: lastError }
    return { list }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) }
  }
}

async function neteaseChart({ id }) {
  const cid = String(id || '3778678')
  const url = `https://music.163.com/api/playlist/detail?id=${encodeURIComponent(cid)}`
  try {
    // 优先走原生 HTTP：WebView 的 fetch 代理请求网易云接口很慢（常要 20 秒以上）
    let data = null
    try {
      const { status, bytes } = await nativeGet(url, NETEASE_HEADERS)
      if (status && status < 400 && bytes && bytes.length) {
        data = JSON.parse(new TextDecoder('utf8').decode(bytes))
      }
    } catch (_) {}
    if (!data) data = await fetchJson(url, NETEASE_HEADERS, 15000)
    const result = (data && data.result) || {}
    const tracks = result.tracks || (result.playlist && result.playlist.tracks) || []
    const list = tracks
      .map((song) => ({
        id: String(song.id || ''),
        title: String(song.name || '').trim(),
        artist: (song.artists || song.ar || []).map((e) => (e && e.name) || '').filter(Boolean).join(' / '),
        album: (song.album && song.album.name) || '',
        duration: Math.round(Number(song.duration) || 0)
      }))
      .filter((item) => item.id && item.title && (!item.duration || item.duration >= 60000))
    if (list.length) writeChartCache(cid, list)
    return { list }
  } catch (err) {
    // 弱网/超时：优先返回上次缓存的榜单，避免歌单空白
    const cached = readChartCache(cid)
    if (cached) return { list: cached.list, stale: true }
    const timeout = err && err.name === 'AbortError'
    return { error: timeout ? '网络超时，请稍后重试' : String(err && err.message ? err.message : err) }
  }
}

async function neteaseToplists() {
  try {
    const data = await fetchJson('https://music.163.com/api/toplist', NETEASE_HEADERS)
    const lists = (data && data.list) || (data && data.playlists) || []
    const list = lists
      .slice(0, 16)
      .map((item) => ({
        id: String(item.id || ''),
        name: String(item.name || '').trim(),
        cover: String(item.coverImgUrl || item.picUrl || ''),
        description: String(item.description || item.copywriter || '')
      }))
      .filter((item) => item.id && item.name)
    if (list.length) {
      try {
        localStorage.setItem('gy_toplists_v1', JSON.stringify(list))
      } catch (_) {}
    }
    return { list }
  } catch (err) {
    try {
      const raw = localStorage.getItem('gy_toplists_v1')
      const list = raw ? JSON.parse(raw) : []
      if (Array.isArray(list) && list.length) return { list }
    } catch (_) {}
    return { error: String(err && err.message ? err.message : err) }
  }
}

async function neteaseLyric({ id }) {
  const sid = String(id || '').trim()
  if (!sid) return { error: '缺少歌曲 ID' }
  try {
    // v1 接口才会返回 yrc（逐字时间轴），KTV 模式靠它把每个字对到真实演唱时刻
    const data = await fetchJson(
      `https://music.163.com/api/song/lyric/v1?id=${encodeURIComponent(sid)}&lv=-1&kv=-1&tv=-1&rv=-1&yv=-1&ytv=-1&yrv=-1`,
      NETEASE_HEADERS
    )
    const lyric = (data && data.lrc && data.lrc.lyric) || ''
    const tlyric = (data && data.tlyric && data.tlyric.lyric) || ''
    const yrc = (data && data.yrc && data.yrc.lyric) || ''
    return { lyric, tlyric, yrc }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) }
  }
}

/* ---------- 咪咕 ---------- */
async function miguSearch({ keyword, limit }) {
  const kw = String(keyword || '').trim()
  if (!kw) return { list: [] }
  const max = Math.max(1, Number(limit) || 400)
  // 咪咕每页固定 20 首，并行翻页
  const pages = Math.max(1, Math.min(20, Math.ceil(max / 20)))
  const pageNos = []
  for (let pageNo = 1; pageNo <= pages; pageNo += 1) pageNos.push(pageNo)
  try {
    const results = await Promise.all(
      pageNos.map((pageNo) =>
        nativeJson(
          `https://app.u.nf.migu.cn/pc/resource/song/item/search/v1.0?text=${encodeURIComponent(kw)}&pageNo=${pageNo}&pageSize=200`,
          { Referer: 'https://music.migu.cn/', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        ).catch(() => null)
      )
    )
    const seen = new Set()
    const list = []
    for (const data of results) {
      const songs = Array.isArray(data) ? data : []
      for (const song of songs) {
        const id = String(song.contentId || '')
        if (!id || !song.songName || seen.has(id)) continue
        // 咪咕返回的 duration 单位是秒，这里统一换算成毫秒，和网易云保持一致
        const seconds = Math.round(Number(song.duration) || 0)
        // 过滤时长不足 2 分钟的片段/试听曲
        if (seconds > 0 && seconds < 120) continue
        seen.add(id)
        list.push({
          id,
          title: String(song.songName).trim(),
          artist: (song.singerList || []).map((e) => (e && e.name) || '').filter(Boolean).join(' / '),
          album: String(song.album || ''),
          duration: seconds * 1000,
          copyrightId: String(song.copyrightId || ''),
          resourceType: String(song.resourceType || '2')
        })
        if (list.length >= max) break
      }
      if (list.length >= max) break
    }
    return { list }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) }
  }
}

async function miguUrl({ contentId, copyrightId, resourceType }) {
  const cid = String(contentId || '').trim()
  if (!cid) return { error: '缺少歌曲 ID' }
  const params = new URLSearchParams({
    contentId: cid,
    copyrightId: String(copyrightId || ''),
    resourceType: String(resourceType || '2'),
    netType: '01',
    toneFlag: 'PQ',
    scene: ''
  })
  try {
    const res = await nativeGet(`https://app.u.nf.migu.cn/strategy/pc/listen/v2.0?${params}`, {
      ...MIGU_HEADERS,
      timestamp: String(Date.now())
    })
    const buf = res.bytes
    const text = new TextDecoder('utf8').decode(buf)
    let body = text
    // 若响应是 hex 字符串，先转回字节再解密
    if (/^[0-9A-Fa-f]+$/.test(text.trim())) {
      const hex = text.trim()
      const bytes = new Uint8Array(hex.length / 2)
      for (let i = 0; i < bytes.length; i += 1) bytes[i] = parseInt(hex.substr(i * 2, 2), 16)
      const decoded = miguDecrypt(bytes)
      if (decoded) body = decoded
    } else {
      const decoded = miguDecrypt(buf)
      if (decoded) body = decoded
    }
    const data = JSON.parse(body)
    const url = data && data.data && data.data.url
    if (url && /^https?:\/\//i.test(url)) return { url: String(url) }
    return { error: (data && data.info) || '该歌曲暂不提供免费播放' }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) }
  }
}

/* ---------- QQ 音乐（vkeys 聚合接口）：网易云/咪咕无版权时的兜底源 ---------- */
const VKEYS_TENCENT = 'https://api.vkeys.cn/v2/music/tencent'
const VKEYS_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  Accept: 'application/json'
}

// "4分30秒" -> 毫秒
function vkeysDuration(text) {
  const match = /(?:(\d+)\s*分)?\s*(\d+)\s*秒/.exec(String(text || ''))
  if (!match) return 0
  return ((Number(match[1]) || 0) * 60 + (Number(match[2]) || 0)) * 1000
}

// "8.70MB" / "920KB" -> MB
function vkeysSizeMB(text) {
  const match = /([\d.]+)\s*(MB|KB)/i.exec(String(text || ''))
  if (!match) return 0
  const value = Number(match[1]) || 0
  return /KB/i.test(match[2]) ? value / 1024 : value
}

async function qqSearch({ keyword, limit }) {
  const kw = String(keyword || '').trim()
  if (!kw) return { list: [] }
  const num = Math.max(1, Math.min(30, Number(limit) || 20))
  try {
    const data = await nativeJson(
      `${VKEYS_TENCENT}?word=${encodeURIComponent(kw)}&page=1&num=${num}`,
      VKEYS_HEADERS,
      12000
    )
    const rows = (data && Array.isArray(data.data) && data.data) || []
    const list = rows
      .map((row) => ({
        id: String(row.mid || row.id || ''),
        title: String(row.song || '').trim(),
        artist: String(row.singer || '').trim(),
        album: String(row.album || ''),
        duration: vkeysDuration(row.interval)
      }))
      .filter((item) => item.id && item.title)
    return { list }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) }
  }
}

async function qqUrl({ mid }) {
  const id = String(mid || '').trim()
  if (!id) return { error: '缺少歌曲 ID' }
  for (const quality of ['8', '6', '4']) {
    try {
      const data = await nativeJson(
        `${VKEYS_TENCENT}?mid=${encodeURIComponent(id)}&quality=${quality}`,
        VKEYS_HEADERS,
        12000
      )
      const item = (data && data.data) || null
      const url = item && item.url
      if (!url || !/^https?:\/\//i.test(url)) continue
      const seconds = vkeysDuration(item.interval) / 1000
      const sizeMB = vkeysSizeMB(item.size)
      // 版权试听片段只有几十秒：按 320kbps 估算，文件明显偏小就换下一档
      const expected = seconds ? (seconds * 40000) / 1048576 : 0
      if (expected && sizeMB && sizeMB < expected * 0.45) continue
      return { url: String(url), duration: seconds * 1000 }
    } catch (_) {}
  }
  return { error: 'QQ 音乐暂无该曲完整版' }
}

/* ---------- 网易云完整版（GD Studio 代理）：绕过 VIP 歌曲的 30 秒试听 ---------- */
const GD_API = 'https://music-api.gdstudio.xyz/api.php'
const GD_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  Accept: 'application/json'
}

async function gdUrl({ id, br }) {
  const sid = String(id || '').trim()
  if (!sid) return { error: '缺少歌曲 ID' }
  try {
    const data = await nativeJson(
      `${GD_API}?types=url&source=netease&id=${encodeURIComponent(sid)}&br=${encodeURIComponent(br || '320')}`,
      GD_HEADERS,
      12000
    )
    const url = data && data.url
    if (url && /^https?:\/\//i.test(url)) {
      return { url: String(url), size: Number(data.size) || 0, br: Number(data.br) || 0 }
    }
    return { error: String((data && (data.message || data.msg)) || '完整版地址获取失败') }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) }
  }
}

/* ---------- 歌曲宝（MusicFree 插件源的网页取链）：多一层完整版兜底 ---------- */
const GQB_BASE = 'https://www.gequbao.com'
const GQB_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'

function gqbDecode(bytes) {
  return bytes && bytes.length ? new TextDecoder('utf8').decode(bytes) : ''
}

function gqbClean(text) {
  return String(text || '')
    .replace(/&amp;/g, '&')
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .trim()
}

async function gqbSearch({ keyword, limit }) {
  const kw = String(keyword || '').trim()
  if (!kw) return { list: [] }
  const max = Math.max(1, Number(limit) || 20)
  try {
    const { status, bytes } = await nativeGet(`${GQB_BASE}/s/${encodeURIComponent(kw)}`, {
      'User-Agent': GQB_UA,
      Referer: `${GQB_BASE}/`
    })
    if (status && status >= 400) return { list: [] }
    const html = gqbDecode(bytes)
    const re = /href="\/music\/(\d+)"[^>]*?title="([^"]*)"/g
    const seen = new Set()
    const list = []
    let match
    while ((match = re.exec(html)) && list.length < max) {
      const id = match[1]
      if (seen.has(id)) continue
      seen.add(id)
      const raw = gqbClean(match[2])
      const split = raw.indexOf(' - ')
      const title = split > 0 ? raw.slice(0, split).trim() : raw
      const artist = split > 0 ? raw.slice(split + 3).trim() : ''
      if (!title) continue
      list.push({ id, title, artist, duration: 0 })
    }
    return { list }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err), list: [] }
  }
}

async function gqbUrl({ id }) {
  const sid = String(id || '').trim()
  if (!sid) return { error: '缺少歌曲 ID' }
  const pageUrl = `${GQB_BASE}/music/${sid}`
  try {
    const page = await nativeGet(pageUrl, { 'User-Agent': GQB_UA, Referer: `${GQB_BASE}/` })
    if (!page || !page.bytes || !page.bytes.length) return { error: '歌曲宝页面获取失败' }
    const html = gqbDecode(page.bytes)
    const found = html.match(/play_id\\u0022:\\u0022([A-Za-z0-9+/=]+)/)
    if (!found) return { error: '未找到播放标识' }
    const cookieHeader = (page.headers && (page.headers['set-cookie'] || page.headers['Set-Cookie'])) || ''
    const cookie = String(cookieHeader)
      .split('\n')
      .map((entry) => String(entry).split(';')[0].trim())
      .filter(Boolean)
      .join('; ')
    const body = `id=${encodeURIComponent(found[1])}&purpose=play`
    const res = await nativeRequest('post', `${GQB_BASE}/member/common-play-url`, {
      'User-Agent': GQB_UA,
      Referer: pageUrl,
      Origin: GQB_BASE,
      'Content-Type': 'application/x-www-form-urlencoded',
      'X-Requested-With': 'XMLHttpRequest',
      ...(cookie ? { Cookie: cookie } : {})
    }, body)
    const text = gqbDecode(res && res.bytes)
    let data = null
    try {
      data = JSON.parse(text)
    } catch (_) {
      data = null
    }
    const url = data && data.data && data.data.url
    if (data && data.code === 1 && url) return { url: String(url) }
    if (data && data.code === 2) return { error: '歌曲宝需要人机验证' }
    return { error: String((data && data.msg) || '歌曲宝未返回播放地址') }
  } catch (err) {
    return { error: String(err && err.message ? err.message : err) }
  }
}

/* ---------- 占位接口 ---------- */
function stub(value) {
  return () => Promise.resolve(value)
}

/* ---------- 电视台直播源：WebView fetch 常常拿不到（TLS/CORS 限制），改走原生 HTTP ---------- */
async function tvFetchText({ url }) {
  const cap = window.Capacitor
  if (cap && typeof cap.nativePromise === 'function') {
    try {
      // 原生请求兜底超时：个别源在原生通道会一直挂着，不能让它拖死页面
      const timeout = new Promise((resolve) => setTimeout(() => resolve(null), 4000))
      const res = await Promise.race([cap.nativePromise('GyHttp', 'get', { url, headers: { 'User-Agent': 'Mozilla/5.0' } }), timeout])
      if (res && typeof res.data === 'string' && res.data) {
        const bin = atob(res.data)
        const bytes = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i)
        return new TextDecoder('utf8').decode(bytes)
      }
      return ''
    } catch (_) {
      return ''
    }
  }
  try {
    const res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } })
    if (!res.ok) return ''
    return await res.text()
  } catch (_) {
    return ''
  }
}

function tvUrlJoin(base, rel) {
  if (/^https?:\/\//i.test(rel)) return rel
  try {
    return new URL(rel, base).toString()
  } catch (_) {
    return rel
  }
}

async function tvNativeBytes(url, timeoutMs) {
  try {
    const timeout = new Promise((resolve) => setTimeout(() => resolve(null), timeoutMs || 2500))
    return await Promise.race([nativeGet(url, { 'User-Agent': 'Mozilla/5.0' }), timeout])
  } catch (_) {
    return null
  }
}

async function tvProbe({ url }) {
  try {
    const first = await tvNativeBytes(url, 5000)
    if (!first || !first.status || first.status >= 400 || !first.bytes || !first.bytes.length) return false
    let text = new TextDecoder('utf8').decode(first.bytes.slice(0, 32768)).trim()
    if (!/^#EXTM3U/i.test(text)) return false
    let base = url
    if (/#EXT-X-STREAM-INF/i.test(text)) {
      const child = text
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line && !line.startsWith('#'))
      if (!child) return false
      base = tvUrlJoin(url, child)
      const second = await tvNativeBytes(base, 5000)
      if (!second || !second.status || second.status >= 400 || !second.bytes) return false
      text = new TextDecoder('utf8').decode(second.bytes.slice(0, 32768)).trim()
    }
    const segs = text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'))
    if (!segs.length) return false
    // 很多线路清单能正常返回，分片却是防盗链/广告页，必须真下第一个分片确认能播
    const candidates = [segs[segs.length - 1], segs[0]]
    for (let i = 0; i < candidates.length; i += 1) {
      const seg = await tvNativeBytes(tvUrlJoin(base, candidates[i]), 8000)
      if (seg && seg.bytes && seg.bytes.length > 1000) {
        const headByte = seg.bytes[0]
        // 0x47 = MPEG-TS，0x73/0x66 = fMP4 的 styp/ftyp
        if (headByte === 0x47 || headByte === 0x73 || headByte === 0x66) return true
      }
    }
    return false
  } catch (_) {
    return false
  }
}

window.api = {
  loadSettings: () => Promise.resolve(loadSettingsFromStorage()),
  saveSettings: (settings) => Promise.resolve(saveSettingsToStorage(settings)),
  pickFolders: stub([]),
  scan: stub([]),
  openPath: stub(''),
  info: () =>
    Promise.resolve({
      name: '娟光阅影',
      version: '1.0.0',
      homeDir: '',
      platform: 'android'
    }),
  openCctv: stub(''),
  ccMusic,
  kugouSearch: stub({ list: [], total: 0 }),
  kugouUrl: stub({ url: '' }),
  qqSearch,
  qqUrl,
  gdUrl,
  gqbSearch,
  gqbUrl,
  neteaseSearch,
  neteaseChart,
  neteaseToplists,
  neteaseLyric,
  tvFetchText,
  tvProbe,
  miguSearch,
  miguUrl,
  qishuiSearch: stub({ list: [], total: 0 }),
  qishuiUrl: stub({ url: '' }),
  qishuiDecrypt: stub(''),
  qishuiCache: stub({}),
  qishuiQr: stub({ img: '' }),
  qishuiStatus: stub({ loggedIn: false }),
  qishuiLoginClose: stub(),
  onQishuiLogin: () => () => {},
  musicLogin: stub({ success: false }),
  openKugou: stub(''),
  openQq: stub(''),
  openDouyin: stub(''),
  openKuaishou: stub(''),
  openQishui: stub(''),
  minimize: () => {},
  toggleMaximize: () => {},
  close: () => {
    // WebView 里 window.close() 不会关闭 Activity，交给原生插件退出
    const cap = window.Capacitor
    if (cap && typeof cap.nativePromise === 'function') {
      cap.nativePromise('Immersive', 'exitApp', {}).catch(() => {})
      return
    }
    try {
      window.close()
    } catch (_) {}
  }
}

/* ---------- 自动识别屏幕：手机 / 平板 / 小屏自适应 ----------
   安卓设备屏幕尺寸差异很大（小屏手机、全面屏手机、平板、折叠屏），
   固定列数会导致平板上封面被拉得过大、小屏手机上内容拥挤。
   这里按实际视口逻辑尺寸判断设备类型，算出网格列数/间距/缩放比例，
   写入 html 属性与 CSS 变量，由样式表统一调整布局；旋屏、分屏、窗口变化时自动重算。 */
;(function () {
  const root = document.documentElement
  if (!root) return

  const clamp = (value, min, max) => Math.max(min, Math.min(max, value))

  function measure() {
    const vw = Math.round(window.innerWidth || root.clientWidth || 0)
    const vh = Math.round(window.innerHeight || root.clientHeight || 0)
    const dw = Math.round((window.screen && window.screen.width) || 0)
    const dh = Math.round((window.screen && window.screen.height) || 0)
    // 分屏/自由窗口时视口会小于物理屏幕，以视口为准；视口异常为 0 时退回屏幕尺寸
    const w = vw > 0 ? vw : dw
    const h = vh > 0 ? vh : dh
    return {
      w,
      h,
      shortSide: Math.max(1, Math.min(w, h)),
      longSide: Math.max(w, h),
      landscape: w > h,
      dpr: window.devicePixelRatio || 1
    }
  }

  function apply() {
    const m = measure()
    const short = m.shortSide
    // 逻辑尺寸（CSS px ≈ dp）：短边 ≥ 600dp 判定为平板
    const tablet = short >= 600

    let size = 'md'
    if (short < 340) size = 'xs'
    else if (short < 380) size = 'sm'
    else if (short < 600) size = 'md'
    else if (short < 840) size = 'lg'
    else size = 'xl'

    const pagePad = tablet ? 22 : size === 'xs' ? 8 : 10
    const gapX = tablet ? 20 : size === 'xs' ? 10 : 14
    const gapY = tablet ? 26 : 22
    // 按「内容区宽度 / 单张封面目标宽度」算列数，平板上目标封面更大，避免两列巨型海报
    const contentW = Math.max(1, m.w - pagePad * 2)
    const targetCard = tablet ? 180 : 152
    const cols = clamp(Math.floor((contentW + gapX) / (targetCard + gapX)), 2, tablet ? 7 : 5)

    // 首页：最新上映共 4 部尽量一行放完；最热 8 部按宽度均分
    const latestCols = tablet ? 4 : m.landscape ? 4 : 2
    const hotCols = tablet ? (contentW >= 1040 ? 8 : 4) : m.landscape ? 4 : 2

    // 电视台的省份板块
    const tvCols = tablet ? (m.landscape ? 6 : 3) : m.landscape ? 4 : 2

    // 平板整体略放大字号/控件；小屏略收紧
    const scale = tablet ? clamp(1 + (short - 600) / 2400, 1, 1.2) : size === 'xs' ? 0.94 : 1

    // 音乐厅竖屏歌单：行高按平板短边等比放大（8 寸 42dp ~ 12.9 寸 58dp），
    // 保证不同尺寸平板都显示 19~22 首，且行内文字与行高同步缩放
    const ttRowH = tablet ? Math.round(clamp(short * 0.065, 42, 58)) : 0
    const ttFont = ttRowH ? Math.round(clamp(ttRowH * 0.26, 13, 15)) : 0
    const ttSubFont = ttRowH ? Math.round(clamp(ttRowH * 0.22, 11, 12)) : 0
    const ttBottom = tablet ? Math.round(clamp(short * 0.042, 24, 36)) : 0
    const ttListW = tablet ? Math.round(clamp(short * 0.31, 220, 340)) : 0

    root.setAttribute('data-gy-screen', tablet ? 'tablet' : 'phone')
    root.setAttribute('data-gy-size', size)
    root.setAttribute('data-gy-orient', m.landscape ? 'landscape' : 'portrait')

    const style = root.style
    style.setProperty('--gy-vw', m.w + 'px')
    style.setProperty('--gy-vh', m.h + 'px')
    style.setProperty('--gy-short', short + 'px')
    style.setProperty('--gy-scale', scale.toFixed(3))
    style.setProperty('--gy-pad', pagePad + 'px')
    style.setProperty('--gy-gap-x', gapX + 'px')
    style.setProperty('--gy-gap-y', gapY + 'px')
    style.setProperty('--gy-cols', String(cols))
    style.setProperty('--gy-latest-cols', String(latestCols))
    style.setProperty('--gy-hot-cols', String(hotCols))
    style.setProperty('--gy-tv-cols', String(tvCols))
    style.setProperty('--gy-tt-row-h', ttRowH ? ttRowH + 'px' : '')
    style.setProperty('--gy-tt-font', ttFont ? ttFont + 'px' : '')
    style.setProperty('--gy-tt-subfont', ttSubFont ? ttSubFont + 'px' : '')
    style.setProperty('--gy-tt-bottom', ttBottom ? ttBottom + 'px' : '')
    style.setProperty('--gy-tt-list-w', ttListW ? ttListW + 'px' : '')
    root.classList.add('gy-screen-ready')
  }

  let delayTimer = 0
  let passes = []

  function refresh() {
    apply()
    // 旋屏后系统栏/安全区会晚一拍才稳定，多拍重算，避免按旧尺寸算错列数
    passes.forEach((id) => clearTimeout(id))
    passes = []
    ;[120, 360, 800].forEach((delay) => passes.push(setTimeout(apply, delay)))
  }

  function schedule() {
    if (delayTimer) clearTimeout(delayTimer)
    delayTimer = setTimeout(refresh, 60)
  }

  window.addEventListener('resize', schedule)
  window.addEventListener('orientationchange', schedule)
  if (window.visualViewport) window.visualViewport.addEventListener('resize', schedule)
  document.addEventListener('DOMContentLoaded', refresh)
  refresh()

  window.GyScreen = { refresh: refresh, measure: measure }
})()


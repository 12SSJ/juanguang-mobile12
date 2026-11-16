/* 代码混淆脚本
   用法：
     node scripts/obfuscate.js desktop   生成 build/obf（electron + src 混淆副本，供 electron-builder 打包）
     node scripts/obfuscate.js android   原地混淆 mobile/android/app/src/main/assets/public 下的 JS
     node scripts/obfuscate.js ios       原地混淆 .tmp/jgm/ios/App/App/public 下的 JS
   只处理 .js，html/css/图片等原样复制或保留，不改变目录结构和文件名。 */

const fs = require('fs')
const path = require('path')
const JavaScriptObfuscator = require('javascript-obfuscator')

const root = path.resolve(__dirname, '..')

const options = {
  compact: true,
  controlFlowFlattening: false,
  deadCodeInjection: false,
  debugProtection: false,
  disableConsoleOutput: false,
  identifierNamesGenerator: 'hexadecimal',
  renameGlobals: false,
  selfDefending: false,
  simplify: true,
  splitStrings: true,
  splitStringsChunkLength: 8,
  stringArray: true,
  stringArrayCallsTransform: true,
  stringArrayEncoding: ['base64'],
  stringArrayIndexShift: true,
  stringArrayRotate: true,
  stringArrayShuffle: true,
  stringArrayThreshold: 0.75,
  stringArrayWrappersCount: 2,
  stringArrayWrappersType: 'function',
  transformObjectKeys: true,
  unicodeEscapeSequence: false
}

function obfuscateFile(filePath) {
  const code = fs.readFileSync(filePath, 'utf8')
  const output = JavaScriptObfuscator.obfuscate(code, options).getObfuscatedCode()
  fs.writeFileSync(filePath, output, 'utf8')
}

/** 原地混淆目录下所有 JS（跳过 *.min.js 与已混淆的第三方库目录） */
function obfuscateInPlace(dir) {
  if (!fs.existsSync(dir)) return 0
  let count = 0
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      if (entry.name === 'vendor') continue
      count += obfuscateInPlace(full)
    } else if (entry.name.endsWith('.js') && !entry.name.endsWith('.min.js')) {
      obfuscateFile(full)
      count++
    }
  }
  return count
}

/** 把源目录整体复制到目标目录，JS 混淆后再写入 */
function obfuscateTo(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true })
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const from = path.join(srcDir, entry.name)
    const to = path.join(destDir, entry.name)
    if (entry.isDirectory()) {
      obfuscateTo(from, to)
    } else if (entry.name.endsWith('.js')) {
      const code = fs.readFileSync(from, 'utf8')
      fs.writeFileSync(to, JavaScriptObfuscator.obfuscate(code, options).getObfuscatedCode(), 'utf8')
    } else {
      fs.copyFileSync(from, to)
    }
  }
}

const target = process.argv[2]
const started = Date.now()

if (target === 'desktop') {
  const out = path.join(root, 'build', 'obf')
  fs.rmSync(out, { recursive: true, force: true })
  obfuscateTo(path.join(root, 'electron'), path.join(out, 'electron'))
  obfuscateTo(path.join(root, 'src'), path.join(out, 'src'))
  console.log(`desktop 混淆完成 -> build/obf（${Date.now() - started}ms）`)
} else if (target === 'android') {
  const count = obfuscateInPlace(path.join(root, 'mobile', 'android', 'app', 'src', 'main', 'assets', 'public'))
  console.log(`android 混淆完成，共 ${count} 个 JS（${Date.now() - started}ms）`)
} else if (target === 'ios') {
  // 工作区内是 .tmp/jgm 子仓库；在 iOS 仓库里直接跑时是 ios/App/App/public
  const dir = [
    path.join(root, 'ios', 'App', 'App', 'public'),
    path.join(root, '.tmp', 'jgm', 'ios', 'App', 'App', 'public')
  ].find((item) => fs.existsSync(item))
  if (!dir) {
    console.error('未找到 iOS public 目录')
    process.exit(1)
  }
  const count = obfuscateInPlace(dir)
  console.log(`ios 混淆完成，共 ${count} 个 JS（${Date.now() - started}ms）`)
} else {
  console.error('用法：node scripts/obfuscate.js desktop|android|ios')
  process.exit(1)
}

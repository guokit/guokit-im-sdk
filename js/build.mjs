// 产物：index.mjs / index.cjs（npm 用，centrifuge 作依赖）、guokit-im.esm.js（打进依赖的 ESM 单文件，uni-app Vue3 用）、
// guokit-im.min.js（IIFE + module.exports，浏览器 script 与微信原生小程序用）、types/。
import { execFileSync } from 'node:child_process'
import { copyFileSync, rmSync } from 'node:fs'
import { build } from 'esbuild'

rmSync('dist', { recursive: true, force: true })
const base = { entryPoints: ['src/index.ts'], bundle: true, target: 'es2017', charset: 'utf8', legalComments: 'none' }
await Promise.all([
  build({ ...base, format: 'esm', external: ['centrifuge'], outfile: 'dist/index.mjs' }),
  build({ ...base, format: 'cjs', external: ['centrifuge'], outfile: 'dist/index.cjs' }),
  build({ ...base, format: 'esm', minify: true, outfile: 'dist/guokit-im.esm.js' }),
  build({
    ...base, format: 'iife', minify: true, globalName: 'GuokitIm', outfile: 'dist/guokit-im.min.js',
    footer: { js: "if(typeof module==='object'&&module.exports)module.exports=GuokitIm;" },
  }),
])
execFileSync('npx', ['tsc', '-p', 'tsconfig.json'], { stdio: 'inherit' })
copyFileSync('../LICENSE', 'LICENSE')

import assert from 'node:assert/strict'
import test from 'node:test'
import mergeSystem from '../opencode/plugins/merge-system/merge-system.js'

const hooks = await mergeSystem()
const transform = hooks['experimental.chat.system.transform']

test('main prompt and injected blocks become one ordered message in place', async () => {
  const system = [
    'You are a coding assistant.\nKeep the existing project conventions.',
    '<date-awareness>2026-09-28</date-awareness>',
    '  Additional project instructions.\n',
  ]
  const expected = system.join('\n\n')
  const output = { system }
  await transform({}, output)
  assert.equal(output.system, system)
  assert.deepEqual(system, [expected])
  await transform({}, output)
  assert.deepEqual(system, [expected], 'a repeated transform must be idempotent')
})

test('blank and non-string blocks do not introduce content or separators', async () => {
  const output = { system: ['', 'main', ' \n\t', null, 42, {}, 'injected'] }
  await transform({}, output)
  assert.deepEqual(output.system, ['main\n\ninjected'])
})

test('empty and single-block arrays remain unchanged', async () => {
  for (const system of [[], ['  keep whitespace\n'], ['']]) {
    const expected = [...system]
    const output = { system }
    await transform({}, output)
    assert.equal(output.system, system)
    assert.deepEqual(system, expected)
  }
})

test('missing or non-array system values are tolerated without mutation', async () => {
  for (const output of [undefined, null, {}, { system: null }, { system: 'main' }]) {
    const expected = structuredClone(output)
    await transform({}, output)
    assert.deepEqual(output, expected)
  }
})

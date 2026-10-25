import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'

describe('PR quality workflow', () => {
  test.each(['server-checks', 'desktop-native-checks', 'coverage-checks'])(
    '%s installs the adapter modules imported by the server and sidecars',
    job => {
      const workflow = readFileSync('.github/workflows/pr-quality.yml', 'utf8')
      const body = workflow.split(`\n  ${job}:`)[1].split(/\n  [a-z-]+:/)[0]
      expect(body).toContain('working-directory: adapters\n        run: bun install')
      expect(body.indexOf('working-directory: adapters')).toBeLessThan(
        body.indexOf('run: bun run check:'),
      )
    },
  )

  test.each(['server-checks', 'coverage-checks'])(
    '%s installs ripgrep before testing file discovery',
    job => {
      const workflow = readFileSync('.github/workflows/pr-quality.yml', 'utf8')
      const body = workflow.split(`\n  ${job}:`)[1].split(/\n  [a-z-]+:/)[0]
      expect(body).toContain('sudo apt-get install -y ripgrep')
      expect(body.indexOf('sudo apt-get install -y ripgrep')).toBeLessThan(
        body.indexOf('run: bun run check:'),
      )
    },
  )

  test('installs root dependencies before running policy tests', () => {
    const workflow = readFileSync('.github/workflows/pr-quality.yml', 'utf8')
    const policyJob = workflow.split('  change-policy:')[1].split('\n  desktop-checks:')[0]
    const install = policyJob.indexOf('run: bun install')
    const tests = policyJob.indexOf('run: bun run check:policy')

    expect(install).toBeGreaterThanOrEqual(0)
    expect(tests).toBeGreaterThan(install)
  })

  test('routes policy outputs into conditional check jobs', () => {
    const workflow = readFileSync('.github/workflows/pr-quality.yml', 'utf8')

    expect(workflow).toContain("if: needs.change-policy.outputs.desktop_checks == 'true'")
    expect(workflow).toContain("if: needs.change-policy.outputs.server_checks == 'true'")
    expect(workflow).toContain("if: needs.change-policy.outputs.adapter_checks == 'true'")
    expect(workflow).toContain("if: needs.change-policy.outputs.desktop_native_checks == 'true'")
    expect(workflow).toContain("if: needs.change-policy.outputs.docs_checks == 'true'")
    expect(workflow).toContain("if: needs.change-policy.outputs.coverage_checks == 'true'")
  })

  test('keeps coverage artifacts observable in CI', () => {
    const workflow = readFileSync('.github/workflows/pr-quality.yml', 'utf8')

    expect(workflow).toContain('COVERAGE_BASE_REF: origin/${{ github.base_ref }}')
    expect(workflow).toContain('cat "$latest_report" >> "$GITHUB_STEP_SUMMARY"')
    expect(workflow).toContain('uses: actions/upload-artifact@v4')
    expect(workflow).toContain('path: artifacts/coverage/')
    expect(workflow).toContain('retention-days: 14')
  })

  test('exposes a single required gate job for branch protection', () => {
    const workflow = readFileSync('.github/workflows/pr-quality.yml', 'utf8')

    expect(workflow).toContain('pr-quality-gate:')
    expect(workflow).toContain('name: pr-quality-gate')
    expect(workflow).toContain('if: always()')
    expect(workflow).toContain('require_success "change-policy" "${{ needs.change-policy.result }}"')
    expect(workflow).toContain('allow_skip_or_success "coverage-checks" "${{ needs.coverage-checks.result }}"')
  })
})

name: pip-audit brew packages

on:
  workflow_dispatch:
  schedule:
    - cron: '0 8 * * *'

jobs:
  audit:
    runs-on: macos-latest
    steps:
      - name: Check out this repo
        uses: actions/checkout@v2
        with:
          fetch-depth: 0
      - run: brew ruby formula2requirements.rb
      - run: bash pip-audit-bulk
      - name: Commit and push if it changed
        run: |-
          git config user.name "Automated"
          git config user.email "actions@users.noreply.github.com"
          git add -A
          timestamp=$(date -u)
          git commit -m "Latest data: ${timestamp}" || exit 0
          git push

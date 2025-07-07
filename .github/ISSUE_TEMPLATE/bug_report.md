---
name: Bug report
about: Create a report to help us improve skhd.zig
title: ''
labels: bug
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. My hotkey configuration that causes the issue:
   ```bash
   # paste relevant lines from your skhdrc here
   ```
2. The application I'm trying to use the hotkey in:
3. What happens when I press the hotkey:
4. Any error messages in the log `/tmp/skhd_$USER.log` (this is usually the configuration error):
   ```bash
   # paste relevant log lines here
   ```

**Expected behavior**
A clear and concise description of what you expected to happen.

**Debug Information**
Please provide debug logs by following these steps:

1. **Get a debug build** (choose one):
   - Download pre-built debug binary from [GitHub Actions](https://github.com/jackielii/skhd.zig/actions/workflows/ci.yml) (click latest run → Artifacts → `skhd-Debug`)
   - Or build from source: `git clone https://github.com/jackielii/skhd.zig && cd skhd.zig && zig build`

2. **Run debug version with verbose logging**:
   ```bash
   # Optional: Stop the service if you're running skhd as a service
   # skhd --stop-service
   
   # Run with verbose logging
   ./skhd -V > skhd-debug.log 2>&1
   ```
   
3. **Reproduce the issue** while skhd is running with verbose logging

4. **Stop skhd** with Ctrl+C and attach the `skhd-debug.log` file to this issue

**Environment**
 - macOS version: [e.g. macOS 14.0 Sonoma]
 - skhd.zig version: (run `skhd --version` to get this)

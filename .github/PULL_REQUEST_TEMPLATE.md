## Summary
Describe the changes in this pull request.

## Checklist
- [ ] `swift test` passes with 0 failures
- [ ] `./Scripts/bundle-app.sh` succeeds cleanly
- [ ] No allocations, locks, logging, or `Task` creation inside realtime audio callbacks (`AppTap`, `MicEngine`, `MonitorPlayback`)
- [ ] Turkish & English UI strings updated where applicable

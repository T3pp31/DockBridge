## Summary
<!-- 変更内容を箇条書きで記載 -->
-

## Test plan
- [ ] `cargo test -p dockbridge-core`
- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --workspace --all-targets -- -D warnings`
- [ ] `xcodebuild -scheme DockBridge -destination 'platform=macOS' build test`
- [ ] `./scripts/e2e-verify.sh`（該当する場合）
- [ ] 手動確認（該当する場合）

<!-- 関連 Issue がある場合: Closes #123 -->

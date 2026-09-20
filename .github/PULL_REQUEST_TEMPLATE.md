## Summary
<!-- 変更内容を箇条書きで記載 -->
-

## Test plan
- [ ] `cargo test --workspace`
- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --workspace --all-targets -- -D warnings`
- [ ] `xcodebuild -scheme DockBridge -destination 'platform=macOS' build test`（macOS / Swift 変更時）
- [ ] `./scripts/generate-uniffi.sh`（UniFFI 境界を変更した場合。生成物の差分もコミット）
- [ ] `./scripts/e2e-verify.sh`（該当する場合）
- [ ] CHANGELOG.md の `[Unreleased]` を更新（ユーザーに見える変更）
- [ ] 手動確認（該当する場合）

<!-- 関連 Issue がある場合: Closes #123 -->

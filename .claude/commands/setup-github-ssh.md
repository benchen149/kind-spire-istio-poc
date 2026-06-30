# GitHub SSH 環境初始化

在新的本地開發環境中，完成 SSH key 產生、GitHub 帳號綁定、gh CLI 登入的一次性設定，使後續可直接執行 `/github-flow`。

## 使用方式

```
/setup-github-ssh
```

## 執行流程

### Step 1：確認環境資訊

詢問使用者：
- **GitHub 帳號 email**（用於 SSH key comment 與 git config）
- **GitHub 帳號 username**（用於 git config）
- **目標 repo 的 remote URL**（若已有本地 clone，自動讀取）

```bash
git remote get-url origin
```

---

### Step 2：安裝 gh CLI（若尚未安裝）

**不可直接 pipe curl 到 sudo**，先下載再安裝，避免供應鏈攻擊：

```bash
if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /tmp/githubcli-archive-keyring.gpg

  file /tmp/githubcli-archive-keyring.gpg | grep -q "PGP\|GPG" || {
    echo "ERROR: 下載的 keyring 格式異常，中止安裝"; exit 1
  }

  sudo cp /tmp/githubcli-archive-keyring.gpg \
    /usr/share/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  rm /tmp/githubcli-archive-keyring.gpg

  echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

  sudo apt update -qq && sudo apt install gh -y -qq
fi
```

---

### Step 3：產生 SSH key（若 `~/.ssh/id_ed25519` 不存在）

**必須設定 passphrase**，保護 private key 在機器被入侵時不被直接使用：

```bash
ssh-keygen -t ed25519 -C "$EMAIL" -f ~/.ssh/id_ed25519
```

產生後顯示公鑰，提示使用者複製：

```bash
cat ~/.ssh/id_ed25519.pub
```

---

### Step 4：加入 GitHub known_hosts 並驗證 fingerprint

**不可直接信任 ssh-keyscan 的結果**，需對比 GitHub 官方公佈的 fingerprint：

```bash
ssh-keyscan github.com > /tmp/github_host_keys 2>/dev/null
ssh-keygen -lf /tmp/github_host_keys
```

人工確認輸出的 fingerprint 是否符合 GitHub 官方值：

```
SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s  (RSA)
SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM  (ECDSA)
SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU  (Ed25519)
```

確認符合後，再加入 known_hosts：

```bash
cat /tmp/github_host_keys >> ~/.ssh/known_hosts
rm /tmp/github_host_keys
```

---

### Step 5：將公鑰加入 GitHub 帳號（需使用者操作）

提示使用者前往：

```
https://github.com/settings/ssh/new
```

- **Title**：填入可識別的機器名稱（`hostname` 指令取得）
- **Key type**：Authentication Key
- **Key**：貼上 Step 3 顯示的公鑰

等待使用者確認完成後繼續。

---

### Step 6：測試 SSH 連線

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh -T git@github.com 2>&1
```

預期出現：`Hi <username>! You've successfully authenticated`

---

### Step 7：切換 git remote 為 SSH

```bash
CURRENT=$(git remote get-url origin)
SSH_URL=$(echo "$CURRENT" | sed 's|https://github.com/|git@github.com:|')
git remote set-url origin "$SSH_URL"
git remote get-url origin
```

---

### Step 8：gh CLI 登入（Fine-grained Token，最小權限原則）

#### 產生 Fine-grained Token 步驟：

1. 前往 `https://github.com/settings/personal-access-tokens/new`
2. **Token name**：填入可識別名稱（如 `kind-spire-istio-poc-<hostname>`）
3. **Expiration**：建議 90 天
4. **Repository access**：選 `Only select repositories` → 選擇 `kind-spire-istio-poc`
5. **Repository permissions** 最小所需權限：
   - Contents：**Read and write**
   - Issues：**Read and write**
   - Pull requests：**Read and write**
   - Metadata：**Read-only**（自動勾選）
6. 產生後複製 token（只顯示一次）

#### 使用 token 登入：

```bash
gh auth login --hostname github.com --git-protocol ssh --with-token <<< "<貼上token>"
gh auth status
```

---

### Step 9：設定 git 身份

```bash
git config --global user.email "$EMAIL"
git config --global user.name "$USERNAME"
```

---

### Step 10：驗證完整環境

```bash
git remote get-url origin   # 應為 git@github.com:... 格式
ssh -T git@github.com 2>&1  # 應出現 Hi <username>!
gh auth status              # 應顯示 Logged in to github.com
git config user.email       # 應顯示正確 email
```

全部通過後提示：環境設定完成，可執行 `/github-flow`。

---

## 安全注意事項

| 項目 | 規範 |
|------|------|
| SSH key passphrase | 必須設定，不可留空 |
| known_hosts | 加入前必須對比 GitHub 官方 fingerprint |
| gh CLI 安裝 | 先下載驗證 GPG keyring 格式，再寫入系統 |
| Token 類型 | 使用 Fine-grained Token，限定單一 repo 與最小權限 |
| Token 有效期 | 建議 90 天，到期重新產生 |
| Token 儲存 | `~/.config/gh/hosts.yml` 為明文，不可納入 git |
| SSH private key | `~/.ssh/id_ed25519` 不可複製到他處、不可提交至任何 repo |

## 注意事項

- SSH key 只需產生一次；若 `~/.ssh/id_ed25519` 已存在，跳過 Step 3
- `ssh-agent` 只在當前 session 有效，重新登入後需再執行 `eval "$(ssh-agent -s)" && ssh-add`
- `1-feat-develop`、`main` 為長期 branch，任何操作皆不可刪除這兩個 branch

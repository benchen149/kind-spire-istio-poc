# GitHub Flow 自動化

執行完整的 GitHub issue → branch → PR → merge 工作流程，或關閉指定的 PR / Issue。

## 使用方式

```
/github-flow
```

執行後會詢問要執行哪個模式。

---

## 模式一：完整開發流程（issue → branch → PR → merge）

### Step 1：收集資訊
詢問使用者：
- **Issue 標題**（例如：`feat: add xxx`，**標題一律使用英文**）
- **Issue 描述**（問題背景、預計異動）
- **Branch slug**（例如：`add-xxx`，會自動加上 issue 編號變成 `{number}-add-xxx`）
- **目標 base branch**（預設 `1-feat-develop`）

### Step 2：開 GitHub Issue

```bash
gh issue create --repo benchen149/kind-spire-istio-poc \
  --title "$TITLE" \
  --body "$BODY"
```

### Step 3：建立並切換 branch（自動執行，不需使用者確認）

```bash
git checkout $BASE_BRANCH
git pull origin $BASE_BRANCH
git checkout -b {issue-number}-$SLUG
```

### Step 4：等待使用者完成改動
branch 建立完成後，提示使用者目前所在 branch 及需要修改的檔案，等待使用者完成程式碼修改後告知 Claude 繼續。

### Step 5：Commit & Push

```bash
git add <changed files>
git commit -m "feat/fix/chore: $TITLE

$DESCRIPTION

Closes #{issue-number}"
git push origin {issue-number}-$SLUG
```

### Step 6：開 Pull Request

```bash
gh pr create \
  --repo benchen149/kind-spire-istio-poc \
  --base $BASE_BRANCH \
  --head {issue-number}-$SLUG \
  --title "$TITLE" \
  --body "$BODY"
```

### Step 7：確認是否 merge
詢問使用者是否直接 merge，若是則：
- merge PR（`merge_method: merge`）
- sync local base branch（`git pull origin $BASE_BRANCH`）
- 自動刪除 feature branch（local + remote），無需詢問使用者
- **絕對不可刪除** `1-feat-develop`、`main` 等長期 branch

```bash
gh pr merge {pr-number} --repo benchen149/kind-spire-istio-poc --merge --delete-branch
git checkout $BASE_BRANCH
git pull origin $BASE_BRANCH
git branch -d {issue-number}-$SLUG
```

### Step 8：sync to main（選用）
若 base branch 不是 `main`，詢問是否開一個 sync PR 將變更合併進 `main`。

開 sync PR 時**必須**在 body 帶入本次相關的 `Closes #X`，讓 GitHub 在 merge 進 main 時自動關閉 issue：

```bash
gh pr create \
  --repo benchen149/kind-spire-istio-poc \
  --base main \
  --head $BASE_BRANCH \
  --title "chore: sync $BASE_BRANCH changes to main" \
  --body "Closes #{issue-number}"
```

> **原因**：GitHub 的 `Closes #X` 只在 PR merge 進 default branch（`main`）時觸發。

---

## Issue 標題準則

- **一律使用英文**撰寫 issue 標題
- 格式：`<type>: <short description>`，例如 `feat: add xxx`、`fix: xxx not working`、`chore: update xxx`

---

## 模式二：關閉 PR / Issue

### 關閉 Issue
```bash
gh issue close {number} --repo benchen149/kind-spire-istio-poc
```

### 關閉 PR
```bash
gh pr close {number} --repo benchen149/kind-spire-istio-poc
```

---

## 注意事項

- `gh` CLI 需已完成登入（執行 `/setup-github-ssh` 完成初始設定）
- base branch 預設為 `1-feat-develop`，若要 merge 到 `main` 請在 Step 1 指定
- `1-feat-develop`、`main` 等長期 branch 不在自動刪除範圍內

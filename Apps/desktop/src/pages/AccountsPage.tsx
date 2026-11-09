import { useMemo, useState } from "react";
import { Avatar } from "../components/Avatar";
import { Badge } from "../components/Badge";
import { Button, IconButton } from "../components/Button";
import { Card, SectionHeader } from "../components/Card";
import { EmptyState } from "../components/EmptyState";
import { Icon } from "../components/Icons";
import { Field, TextInput } from "../components/Input";
import { ConfirmDialog } from "../components/Modal";
import { PageHeader } from "../components/PageHeader";
import { useApp } from "../stores/app";
import { formatDate, shortUuid } from "../lib/format";

function skinOf(account: { skinTextureUrl?: string | null; skinTextureURL?: string | null }) {
  return account.skinTextureUrl ?? account.skinTextureURL ?? null;
}

export function AccountsPage() {
  const {
    accounts,
    activeProfile,
    activeAccount,
    refreshAccounts,
    setActiveAccount,
    createLocalAccount,
    deleteLocalAccount,
    signOutMicrosoft,
    beginMicrosoftLogin,
    cancelMicrosoftLogin,
    toast,
  } = useApp();

  const [refreshing, setRefreshing] = useState(false);
  const [name, setName] = useState("");
  const [nameTouched, setNameTouched] = useState(false);
  const [creating, setCreating] = useState(false);
  const [loginUrl, setLoginUrl] = useState<string | null>(null);
  const [loggingIn, setLoggingIn] = useState(false);
  const [deleteName, setDeleteName] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [busyKey, setBusyKey] = useState<string | null>(null);

  const nameLength = useMemo(() => Array.from(name.trim()).length, [name]);
  const nameError =
    nameTouched && (nameLength < 3 || nameLength > 16)
      ? "玩家名称需要 3-16 个字符"
      : null;
  const canCreate = nameLength >= 3 && nameLength <= 16 && !creating;

  function isActive(kind: "microsoft" | "local", identifier: string) {
    return activeAccount?.kind === kind && activeAccount.identifier === identifier;
  }

  async function handleRefresh() {
    setRefreshing(true);
    try {
      await refreshAccounts();
    } finally {
      setRefreshing(false);
    }
  }

  async function handleCreate(event: React.FormEvent) {
    event.preventDefault();
    setNameTouched(true);
    if (!canCreate) return;
    setCreating(true);
    try {
      const account = await createLocalAccount(name.trim());
      if (account) setName("");
    } finally {
      setCreating(false);
    }
  }

  async function handleSetActive(kind: "microsoft" | "local", identifier: string) {
    setBusyKey(`${kind}:${identifier}`);
    try {
      await setActiveAccount(kind, identifier);
    } finally {
      setBusyKey(null);
    }
  }

  async function handleDelete() {
    if (!deleteName) return;
    setDeleting(true);
    try {
      await deleteLocalAccount(deleteName);
      setDeleteName(null);
    } catch {
      // Store handles the error toast.
    } finally {
      setDeleting(false);
    }
  }

  async function handleLogin() {
    setLoggingIn(true);
    try {
      const url = await beginMicrosoftLogin();
      if (url) setLoginUrl(url);
    } finally {
      setLoggingIn(false);
    }
  }

  async function handleCancelLogin() {
    await cancelMicrosoftLogin();
    setLoginUrl(null);
  }

  async function copyLoginUrl() {
    if (!loginUrl) return;
    try {
      await navigator.clipboard.writeText(loginUrl);
      toast("success", "登录链接已复制");
    } catch {
      toast("error", "复制失败", "请手动选择链接复制。");
    }
  }

  return (
    <>
      <PageHeader
        eyebrow="Account / 身份"
        title="账户管理"
        subtitle="连接 Microsoft 账户以使用正版皮肤与服务器，或创建本地离线账户快速进入游戏。"
        actions={
          <>
            <Button variant="secondary" icon="refresh" loading={refreshing} onClick={() => void handleRefresh()}>
              刷新账户
            </Button>
            <Button variant="primary" icon="login" loading={loggingIn} onClick={() => void handleLogin()}>
              登录 Microsoft
            </Button>
          </>
        }
      />

      <div className="page-stack">
        <div className="account-summary">
          <div className="account-summary__identity">
            <Avatar name={activeProfile?.name ?? null} skinUrl={activeProfile?.skinUrl ?? null} size={58} ring />
            <div>
              <p className="overline">当前身份</p>
              <h2>{activeProfile?.name ?? "未登录"}</h2>
              <p className="caption">
                {activeProfile
                  ? activeProfile.kind === "microsoft"
                    ? "Microsoft 账户 · 正版验证已启用"
                    : "本地离线账户 · 仅离线游戏"
                  : "选择一个账户作为启动身份"}
              </p>
            </div>
          </div>
          <div className="account-summary__stats">
            <div><strong>{accounts.microsoft.length}</strong><span>Microsoft</span></div>
            <div><strong>{accounts.local.length}</strong><span>离线账户</span></div>
          </div>
        </div>

        {loginUrl ? (
          <Card className="login-pending">
            <div className="login-pending__head">
              <span className="login-pending__pulse" aria-hidden="true" />
              <div>
                <h3>等待 Microsoft 登录完成</h3>
                <p className="caption">请在浏览器中打开下面的链接并完成授权。成功后账户列表会自动刷新。</p>
              </div>
              <Button variant="ghost" size="sm" onClick={() => void handleCancelLogin()}>
                取消登录
              </Button>
            </div>
            <div className="login-pending__url">
              <code>{loginUrl}</code>
              <IconButton icon="copy" label="复制登录链接" onClick={() => void copyLoginUrl()} />
            </div>
          </Card>
        ) : null}

        <section>
          <SectionHeader
            title="Microsoft 账户"
            caption="通过 Microsoft OAuth 登录，支持正版服务器与皮肤"
            action={
              <Button variant="secondary" size="sm" icon="plus" loading={loggingIn} onClick={() => void handleLogin()}>
                添加账户
              </Button>
            }
          />
          {accounts.microsoft.length === 0 ? (
            <EmptyState
              icon="user"
              title="暂无 Microsoft 账户"
              description="登录 Microsoft 账户后，启动器会同步你的玩家档案、皮肤与披风。"
              action={
                <Button variant="primary" icon="login" loading={loggingIn} onClick={() => void handleLogin()}>
                  登录 Microsoft
                </Button>
              }
            />
          ) : (
            <div className="account-list">
              {accounts.microsoft.map((account) => {
                const current = isActive("microsoft", account.id);
                return (
                  <Card key={account.id} className={`account-card ${current ? "is-active" : ""}`}>
                    <Avatar name={account.playerName} skinUrl={skinOf(account)} size={46} />
                    <div className="account-card__copy">
                      <div className="account-card__title">
                        <h3>{account.playerName}</h3>
                        {current ? <Badge tone="success" dot>当前使用</Badge> : <Badge tone="outline">Microsoft</Badge>}
                      </div>
                      <p className="caption">
                        {account.uuid ? `UUID ${shortUuid(account.uuid)}` : "未获取 UUID"}
                        {account.signedInAt ? ` · 登录于 ${formatDate(account.signedInAt)}` : ""}
                      </p>
                    </div>
                    <div className="account-card__actions">
                      {!current ? (
                        <Button
                          variant="secondary"
                          size="sm"
                          loading={busyKey === `microsoft:${account.id}`}
                          onClick={() => void handleSetActive("microsoft", account.id)}
                        >
                          设为当前
                        </Button>
                      ) : null}
                      <Button variant="ghost" size="sm" icon="refresh" loading={loggingIn} onClick={() => void handleLogin()}>
                        重新登录
                      </Button>
                      <Button variant="ghost" size="sm" icon="logout" onClick={() => void signOutMicrosoft(account.id)}>
                        退出
                      </Button>
                    </div>
                  </Card>
                );
              })}
            </div>
          )}
        </section>

        <div className="accounts-columns">
          <section>
            <SectionHeader title="离线账户" caption="保存在本地的玩家档案，不进行身份验证" />
            {accounts.local.length === 0 ? (
              <EmptyState
                icon="user"
                title="暂无离线账户"
                description="创建一个离线账户，在不联网的情况下也能进入单人游戏。"
                compact
              />
            ) : (
              <div className="account-list">
                {accounts.local.map((account) => {
                  const current = isActive("local", account.name);
                  return (
                    <Card key={account.name} className={`account-card account-card--compact ${current ? "is-active" : ""}`}>
                      <Avatar name={account.name} size={40} />
                      <div className="account-card__copy">
                        <div className="account-card__title">
                          <h3>{account.name}</h3>
                          {current ? <Badge tone="success" dot>当前使用</Badge> : <Badge tone="outline">离线</Badge>}
                        </div>
                        <p className="caption">
                          {account.uuid ? shortUuid(account.uuid) : "本地档案"}
                          {account.createdAt ? ` · 创建于 ${formatDate(account.createdAt)}` : ""}
                        </p>
                      </div>
                      <div className="account-card__actions">
                        {!current ? (
                          <Button
                            variant="ghost"
                            size="sm"
                            loading={busyKey === `local:${account.name}`}
                            onClick={() => void handleSetActive("local", account.name)}
                          >
                            使用
                          </Button>
                        ) : null}
                        <IconButton
                          icon="trash"
                          label={`删除离线账户 ${account.name}`}
                          variant="danger"
                          onClick={() => setDeleteName(account.name)}
                        />
                      </div>
                    </Card>
                  );
                })}
              </div>
            )}
          </section>

          <Card className="create-account">
            <SectionHeader title="创建离线账户" caption="3-16 个字符，支持中文与字母" />
            <form onSubmit={(event) => void handleCreate(event)} className="create-account__form">
              <Field id="local-account-name" label="玩家名称" hint="将显示在游戏内，创建后可随时切换。" error={nameError ?? undefined}>
                <TextInput
                  id="local-account-name"
                  value={name}
                  maxLength={16}
                  leadingIcon="user"
                  placeholder="例如 Lingxi"
                  onBlur={() => setNameTouched(true)}
                  onChange={(event) => {
                    setName(event.target.value);
                    if (!nameTouched) setNameTouched(true);
                  }}
                />
              </Field>
              <div className="create-account__counter">
                <span className={nameLength > 16 ? "text-danger" : ""}>{nameLength}</span> / 16
              </div>
              <Button type="submit" variant="primary" icon="plus" block disabled={!canCreate} loading={creating}>
                创建并保存
              </Button>
            </form>
            <div className="callout create-account__note">
              <Icon name="info" size={14} className="callout__icon" />
              <p>离线账户不能加入开启了正版验证的服务器。请支持正版。</p>
            </div>
          </Card>
        </div>
      </div>

      {deleteName ? (
        <ConfirmDialog
          title="删除离线账户"
          description={`确定删除离线账户「${deleteName}」吗？该操作只会移除本地档案。`}
          confirmLabel="删除账户"
          busy={deleting}
          onConfirm={() => void handleDelete()}
          onCancel={() => setDeleteName(null)}
        />
      ) : null}
    </>
  );
}

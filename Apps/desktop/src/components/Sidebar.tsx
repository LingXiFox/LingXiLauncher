import { Avatar } from "./Avatar";
import { Icon, FoxMark, type IconName } from "./Icons";
import { useApp, type Section } from "../stores/app";

interface NavItem {
  section: Section;
  label: string;
  icon: IconName;
  badge?: number;
}

interface NavGroup {
  label: string;
  items: NavItem[];
}

export function Sidebar() {
  const { section, setSection, instances, activeProfile, version, resolvedTheme } = useApp();

  const groups: NavGroup[] = [
    {
      label: "Play",
      items: [{ section: "home", label: "首页", icon: "home" }],
    },
    {
      label: "Library",
      items: [
        { section: "instances", label: "游戏实例", icon: "layers", badge: instances.length },
        { section: "downloads", label: "版本下载", icon: "download" },
      ],
    },
    {
      label: "Account",
      items: [{ section: "accounts", label: "账户管理", icon: "user" }],
    },
    {
      label: "System",
      items: [
        { section: "logs", label: "运行日志", icon: "logs" },
        { section: "settings", label: "设置", icon: "settings" },
      ],
    },
  ];

  const accountType = activeProfile
    ? activeProfile.kind === "microsoft"
      ? "Microsoft 账户"
      : "离线账户"
    : "点击登录账户";

  return (
    <aside className="sidebar" aria-label="主导航">
      <div className="sidebar__brand">
        <span className="sidebar__mark" aria-hidden="true">
          <FoxMark size={30} />
        </span>
        <span className="sidebar__brand-text">
          <span className="sidebar__brand-name">LINGXI</span>
          <span className="sidebar__brand-sub">LAUNCHER</span>
        </span>
        <span className="sidebar__edition" title={`灵曦启动器 ${version}`}>
          v{version.replace(/^v/i, "")}
        </span>
      </div>

      <nav className="sidebar__nav">
        {groups.map((group) => (
          <div className="nav-group" key={group.label}>
            <p className="overline nav-group__label">{group.label}</p>
            <ul className="nav-list">
              {group.items.map((item) => {
                const active = section === item.section;
                return (
                  <li key={item.section}>
                    <button
                      type="button"
                      className={["nav-item", active ? "is-active" : ""].filter(Boolean).join(" ")}
                      aria-current={active ? "page" : undefined}
                      onClick={() => setSection(item.section)}
                    >
                      <span className="nav-item__bar" aria-hidden="true" />
                      <Icon name={item.icon} size={17} className="nav-item__icon" />
                      <span className="nav-item__label">{item.label}</span>
                      {typeof item.badge === "number" && item.badge > 0 ? (
                        <span className="nav-item__badge">{item.badge}</span>
                      ) : null}
                    </button>
                  </li>
                );
              })}
            </ul>
          </div>
        ))}
      </nav>

      <div className="sidebar__footer">
        <button type="button" className="sidebar-account" onClick={() => setSection("accounts")}>
          <Avatar name={activeProfile?.name ?? null} skinUrl={activeProfile?.skinUrl ?? null} size={34} ring />
          <span className="sidebar-account__copy">
            <span className="sidebar-account__name">{activeProfile?.name ?? "未登录"}</span>
            <span className="sidebar-account__type">{accountType}</span>
          </span>
          <Icon name="chevronRight" size={14} className="sidebar-account__chevron" />
        </button>
        <div className="sidebar__meta">
          <span className={["sidebar__status-dot", resolvedTheme === "light" ? "is-light" : ""].join(" ")} aria-hidden="true" />
          <span>灵曦启动器</span>
          <span className="sidebar__meta-sep">·</span>
          <span>v{version.replace(/^v/i, "")}</span>
        </div>
      </div>
    </aside>
  );
}

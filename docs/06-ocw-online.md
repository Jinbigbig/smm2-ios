# 06 · 让 iOS 版联网：OpenCourse World 方案

> 本篇只讲**联机链路怎么打通**。前提是游戏已经能在设备上单机跑起来（见 00–03）。
> 结论先行：官方联网后端在自签 iOS 版上不可用，能走通的只有 **OCW（OpenCourse World）** 一条路。

---

## 1. 为什么"点联机就报错"不是移植 bug

SMM2 的联网走 `nn::nex` 一类的官方服务栈，登录需要设备证书 + Nintendo Account 票据，且服务端会校验客户端完整性。自签重编译版既没有合法票据，也改了可执行体，这条路从协议层就没有解。

移植层因此设计了**后端可切换**机制：从数据目录的 `smm2mods.ini` 读取 `backend=` 一行，决定把游戏自带的联网客户端指向哪个服务。

| `backend` 取值 | 指向 | 在自签 iOS 上是否可用 |
|---|---|---|
| 空缺 / `official` | 官方服务 | 否，无票据且被完整性校验拦下 |
| `ocw` | OpenCourse World | **是**，普通 HTTPS，公网可达即可 |
| 其它第三方 | 各自实现 | 视其是否要求客户端校验 |

先确认一件事：**没配置时日志里会有明确的"关闭"提示**（形如 `no ocw-config.json ... stays off`），出现它说明后端压根没启用，不是网络问题——先补配置，再谈排障。

## 2. 配置契约：两个文件、四个字段

OCW 要求以下两个文件**同放数据目录**，缺一不可：

### 2.1 `ocw-config.json`

```json
{ "domain": "server.opencourse.world", "token": "<22 位字符串>" }
```

| 字段 | 约束 | 说明 |
|---|---|---|
| `domain` | **≤ 29 字符** | 游戏侧主机名槽位长度固定，超长会被截断或拒绝 |
| `token` | **恰好 22 字符** | 站点下发的账号凭据，长度写死在槽位里，非 22 位视为无效 |

`server.opencourse.world` 正好 23 字符，在槽位内。

### 2.2 `smm2mods.ini`

```ini
courses=tgrcode
ruleset=hundred
hundred=1
backend=ocw
```

- `backend=ocw` 是**必须**的一行，缺它等于没配。
- 其余行是本机玩法相关的开关，按需保留；从别处拷来的 ini 不要整段覆盖，追加/改 `backend=` 即可。

## 3. 两个落点

| 端 | 数据根 | 备注 |
|---|---|---|
| 桌面端（Apple silicon 本机调试） | `~/Library/Application Support/org.smcraft.smm2recomp/` | 无沙箱，直接读写 |
| iOS 真机 | App 沙箱 `Documents/` | 重装清空，需重推 |

iOS 侧的数据根固定为 `$HOME/Documents`（沙箱内即 App 的 Documents）。

> 打包时把配置放进 `.app/data/` **不会自动生效**——`ios_link_bundle_data()` 的白名单只有 `extracted` / `fonts` / `sysdata` / `metallib` / `smm1`，配置文件不在其中。要让配置随包走，需走 `07` 篇的首启自复制。

## 4. 落配置的两条路

### 4.1 推荐：随包自带，首启自动复制

见 [07-settings-in-bundle.md](07-settings-in-bundle.md)。配置打进 `.app/data/`，首次启动时由 `ios_seed_bundle_config()` 复制到 `Documents/`，已存在则跳过。好处是装完即用，不需要额外步骤。

### 4.2 手动：`scripts/push-ocw.sh`

用于重装后补配置、换设备、或想临时切 token：

```bash
./scripts/push-ocw.sh                    # 默认设备名 mm、bundle id app.grape2286.yam856
./scripts/push-ocw.sh -d "我的 iPhone"    # 指定设备（名称或 UDID）
./scripts/push-ocw.sh -c ./ocw-config.json
./scripts/push-ocw.sh -n                 # 只看不写
```

脚本行为：

1. 用 `devicectl device copy from` 把设备上现有的 `smm2mods.ini` 抓下来；
2. 保留其它行，只把 `backend=` 改写为 `ocw`（没有该行就追加）；
3. 推送 `ocw-config.json` 与改好的 `smm2mods.ini` 到 `Documents/`；
4. 回读两个文件，`cmp` 校验 JSON 一致、`grep` 校验 `backend=ocw` 存在。

**配置只在启动时读一次**，推完必须冷启动（从后台划掉再开），不要只切前台。

## 5. 验收：日志三正一负

启动后拉日志（`xcrun devicectl device process launch --console`，或 `device copy from Documents/smm2recomp.log`）：

```
[net] backend ocw: the game's own online client against OpenCourse World,
      certificate checked against the public roots and the host name
[ocw] host "server.opencourse.world" written at main+0x22cc307
[ssl] connection to server.opencourse.world (x.x.x.x): TLS 1.2,
      trust: the public roots and the host name
```

三条齐全即链路成立——游戏自带的联网客户端已被重定向到 OCW，且 TLS 用系统公共根证书校验通过（自签 IPA 未改 TLS 校验逻辑）。

反向判据：日志里若仍有

```
no ocw-config.json ... stays off
```

说明配置没到位（文件不存在 / 不在 `Documents/` / 没有 `backend=ocw`），不要继续查网络。

## 6. 网络侧排查顺序

按以下顺序试，逐层排除，能确诊时立即停：

1. **先探后端是否可达**（外网 443 直连）：
   ```bash
   curl -sSI --max-time 8 https://server.opencourse.world/ | head -1
   ```
   拿到任意 HTTP 响应即说明链路通。
2. **受限网络先换载体**：家宽/办公网可能对未知域名做 DNS 投毒或直接丢包。切 iPhone 蜂窝热点再测一次，通常一次就通。
3. **代理不是必需的**：本仓库验证过的成功路径是**直连**，未依赖代理。反向代理 / 全局代理反而可能让 TLS 校验或长连接出问题，能直连就别套。
4. **业务接口返回 500 属正常**：例如 `server.opencourse.world/api/connect/twitch` 在缺参时返回 HTTP 500，这是业务层响应，恰证明后端可达且服务在跑，不要当网络故障。
5. **第三方 OAuth 可能被阻断**：Twitch / Discord 之类的联动页在受限网络下可能打不开。**这不影响主联机链路**——账号注册完成后，游戏内联机走的是 OCW 自己的长连接，与这些 OAuth 页面无关。

## 7. 易踩的四个点

| 现象 | 原因 | 处理 |
|---|---|---|
| 重装后又联不上 | 沙箱 `Documents/` 被清空，配置没了 | 重推配置，或改用随包自带（07 篇） |
| 昨天能用，今天 token 失效 | `ocw-config.json` 从站点**重复下载**会作废旧 token | 只保留一份，别反复下载；需要时以最新一份为准 |
| 推完没生效 | 配置只在启动时读取 | 冷启动，`--terminate-existing` |
| 配置两个文件齐了仍 `stays off` | 放错层级（放进了 `Documents/xxx/` 子目录）或 JSON 非法 | 必须在 `Documents/` 根；`python3 -m json.tool` 验一下 |

## 8. 安全提醒

`ocw-config.json` 里的 `token` 是账号凭据，**不要提交到仓库、不要发给他人**。本仓库所有文档与脚本均以占位符表示，不含真实 token。

# IaC-terraform — 3 節點 k3s 叢集（AWS）

用 Terraform 在 AWS 上開三台 EC2，手動安裝 **k3s** 組成 1 master + 2 worker 的 Kubernetes 叢集。

---

## 架構

| 項目 | 值 |
|------|-----|
| Region | `ap-northeast-2`（首爾） |
| VPC | `10.0.0.0/16`（`dev-vpc`） |
| Subnet | `10.0.1.0/24`（public，`ap-northeast-2b`） |
| Security Group | `dev-web-sg` |
| 機型 | `t3.small`（2GB）× 3，Amazon Linux 2 |
| 對外 | 每台有 public IP，route 走 IGW |

| 節點 | 角色 | Private IP（範例，實際以你的為準） |
|------|------|------|
| `child-1` | **master**（k3s server / control-plane） | `10.0.1.106` |
| `child-2` | worker（k3s agent） | `10.0.1.175` |
| `child-3` | worker（k3s agent） | `10.0.1.231` |

**Security Group 規則**
- Ingress `80/tcp` ← VPC CIDR（`10.0.0.0/16`）
- Ingress `22/tcp` ← EC2 Instance Connect prefix list
- Ingress **all ← 同一個 SG 自己（`self = true`）** ← k3s 節點互通必備（6443 / flannel 8472-UDP / kubelet 10250…）
- Egress all → `0.0.0.0/0`

---

## 前置需求

- 已安裝 Terraform，且設定好 AWS 認證（`aws configure` 或環境變數）。
- 連線方式：AWS Console → 選 instance → **Connect** → **EC2 Instance Connect**（SG 只開放這個來源 SSH）。

---

## Step 1：用 Terraform 開基礎建設

```bash
terraform init
terraform plan      # 確認要建立/變更的資源
terraform apply
```

> ⚠️ 改 `instance_type` 是 **in-place**（stop→改型→start，資料保留，但 public IP 會換新）。
> 改 `ami` / `subnet_id` / `az` 會 **強制重建**（資料會沒）。

---

## Step 2：安裝 k3s

> **Amazon Linux 2 重要前提**——AL2 太舊，有兩個必加的設定，否則一定失敗：
> 1. **`INSTALL_K3S_CHANNEL=v1.30`** — AL2 是 cgroup v1，新版 k3s（k8s ≥ 1.36）的 kubelet 拒絕在 cgroup v1 上跑，必須 pin 到 1.30 線。
> 2. **`INSTALL_K3S_SKIP_SELINUX_RPM=true`** — AL2 的 selinux-policy 太舊，`k3s-selinux` RPM 裝不起來，必須跳過（AL2 SELinux 預設 Disabled，跳過安全）。
>
> 這兩個 flag **每一台、每一次** 安裝都要帶。

### 2-1. master（child-1）

```bash
# （選用）2GB 無 swap 的保險：關掉吃資源的附加元件
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
disable:
  - traefik
  - servicelb
  - metrics-server
EOF

# 安裝 k3s server
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL=v1.30 \
  INSTALL_K3S_SKIP_SELINUX_RPM=true \
  sh -

# 驗證（注意：sudo 找不到 k3s，要用絕對路徑）
sudo ss -lntp | grep 6443                      # 6443 要有 listen
sudo /usr/local/bin/k3s kubectl get nodes      # master 要 Ready

# 抄下這兩個值給 worker 用
sudo cat /var/lib/rancher/k3s/server/node-token   # ← TOKEN
hostname -I | awk '{print $1}'                     # ← master private IP
```

### 2-2. worker（child-2 / child-3）

把 `<MASTER_IP>` 和 `<TOKEN>` 換成上面抄到的值，兩台各跑一次：

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL=v1.30 \
  INSTALL_K3S_SKIP_SELINUX_RPM=true \
  K3S_URL=https://<MASTER_IP>:6443 \
  K3S_TOKEN=<TOKEN> \
  sh -

# 驗證 agent（worker 的服務叫 k3s-agent）
sudo systemctl status k3s-agent --no-pager
```

> worker 的 k3s 版本要跟 master 一致（都用 `INSTALL_K3S_CHANNEL=v1.30`）。

### 2-3. 回 master 確認三台都進來

```bash
sudo /usr/local/bin/k3s kubectl get nodes
```

三台都 `Ready` 即完成。

---

## Step 3：收尾設定（選用）

**幫 worker 加上 `worker` 角色標籤**（k3s 不會自動加，ROLES 預設 `<none>`，純顯示用途）：

```bash
sudo /usr/local/bin/k3s kubectl label node <worker節點名> node-role.kubernetes.io/worker=worker
```

**讓 `kubectl` 免 sudo、免絕對路徑**（在 master）：

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
export KUBECONFIG=~/.kube/config
kubectl get nodes
```

---

## 疑難排解（本專案實際踩過的雷）

| 症狀 | 原因 | 解法 |
|------|------|------|
| 安裝卡在 `k3s-selinux` RPM 依賴錯誤 | AL2 selinux-policy 太舊 | 加 `INSTALL_K3S_SKIP_SELINUX_RPM=true` |
| server crash-loop，log 出現 `kubelet ... cgroup v1 ... unsupported` | AL2 是 cgroup v1，新版 k3s 拒跑 | 加 `INSTALL_K3S_CHANNEL=v1.30` 降版 |
| `sudo k3s: command not found` | `/usr/local/bin` 不在 sudo secure_path | 用絕對路徑 `sudo /usr/local/bin/k3s ...` |
| worker join 卡在 `Starting k3s-agent` / 連不到 6443 | SG 沒放行節點間流量 | 確認 SG 有 `self = true` 的 ingress 並已 apply |
| `failed to bootstrap cluster data` | 反覆重裝留下不一致的 datastore | `sudo /usr/local/bin/k3s-uninstall.sh` 清乾淨再重裝 |
| worker ROLES 顯示 `<none>` | 正常，k3s 不自動標 worker | 手動加 `node-role.kubernetes.io/worker` 標籤（選用） |

> 更根本的解法：把 AMI 換成 **Amazon Linux 2023**（原生 cgroup v2 + 新 systemd），可一次免除 cgroup 與 SELinux 兩個問題（但改 `ami` 會重建三台）。

---

## ⚠️ 成本提醒

- **`t3.small` 不在 AWS Free Tier**（free tier 只有 micro，且 750 小時/月跨所有 instance 共用）。
- 三台 `t3.small` 開 24/7 約 **$50–60/月**。
- **不用時請 `terraform destroy` 或在 Console 停機**，只算實際開機時數。

---

## ⚠️ 資料持久化（重要觀念）

被 Terraform 管的 EC2 要當「**牲口不是寵物**」，隨時可砍可重建。**不要把 DB 等有狀態資料放在 node 本機 / pod 暫存層**，否則 node 一被 `destroy` / replace 就沒了。

- k3s 預設的 `local-path` PVC 是存在「那台 node 的本機磁碟」→ **node 被砍就沒**。
- 要抗重建，依省心程度：**RDS**（最省心）／獨立 `aws_ebs_volume` + `aws_volume_attachment`／**EBS CSI 撐的 PVC**。
- 不論哪種，**定期備份**（dump 到 S3、EBS snapshot）。

---

## 清除

```bash
terraform destroy
```

> 會刪掉**這份 Terraform state 管的**資源（VPC / subnet / SG / 3 台 EC2）。不會動到你手動建立、或預設的 VPC。

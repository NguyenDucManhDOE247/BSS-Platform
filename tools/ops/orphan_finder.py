#!/usr/bin/env python3
"""orphan_finder.py — sau `terraform destroy`, liệt kê tài nguyên BSS còn sót mà VẪN TÍNH TIỀN.

Vì sao cần (B-37, bài 02 mục 5.1): một số thứ KHÔNG nằm trong state Terraform nên `destroy` không biết
để xóa — ALB/Target Group do AWS Load Balancer Controller tạo từ Ingress, EC2 do Karpenter tạo (ADR-010),
ENI/EBS do addon để lại. Chúng sống tiếp và tính tiền ("hóa đơn ma"). `scripts/teardown.sh` đã dọn chủ
động (xóa Ingress + NodePool trước destroy); script này là lưới an toàn KIỂM LẠI sau đó.

Chỉ ĐỌC — không tạo/sửa/xóa gì (nên không cần `--dry-run`: không có gì để "chạy thử").
Exit code: 0 = sạch, 1 = còn sót (dùng được làm cổng kiểm trong script khác), 2 = lỗi gọi AWS.

Tài nguyên BỀN của `environments/shared` (ECR, OIDC provider, role deployer, bucket state, zone Route 53 +
cert ACM — ADR-012) là CỐ Ý tồn tại lâu dài (ADR-003/006) → không bị coi là mồ côi; chỉ BẢN GHI DNS của
cluster đã xóa mới bị báo.

Usage:
    python tools/ops/orphan_finder.py
    python tools/ops/orphan_finder.py --region ap-southeast-1 --json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass

import boto3
from botocore.exceptions import BotoCoreError, ClientError

PREFIX = "bss-"  # name_prefix mọi môi trường: bss-dev / bss-staging / bss-prod
PROJECT_TAG = ("Project", "bss-platform")


@dataclass
class Orphan:
    kind: str
    id: str
    detail: str


def _tags(items: list[dict] | None) -> dict[str, str]:
    return {t["Key"]: t["Value"] for t in (items or [])}


def _is_bss(tags: dict[str, str], name: str = "") -> bool:
    """Thuộc BSS nếu mang tag Project, tag cluster bss-*, tag Karpenter/ALB controller của cluster bss-*, hoặc tên bss-*."""
    if tags.get(PROJECT_TAG[0]) == PROJECT_TAG[1] or name.startswith(PREFIX):
        return True
    for key, value in tags.items():
        if key.startswith("kubernetes.io/cluster/" + PREFIX):
            return True
        if key in ("eks:cluster-name", "elbv2.k8s.aws/cluster", "karpenter.sh/discovery") and value.startswith(PREFIX):
            return True
    return False


def find_ec2(ec2) -> list[Orphan]:
    out: list[Orphan] = []
    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]}]
    )
    for page in pages:
        for res in page["Reservations"]:
            for inst in res["Instances"]:
                tags = _tags(inst.get("Tags"))
                if _is_bss(tags):
                    who = "Karpenter" if "karpenter.sh/nodepool" in tags else tags.get("eks:nodegroup-name", "?")
                    out.append(Orphan("EC2", inst["InstanceId"], f"{inst['InstanceType']} {inst['State']['Name']} ({who})"))
    return out


def find_nat_eip_ebs_eni(ec2, live_clusters: set[str]) -> list[Orphan]:
    out: list[Orphan] = []
    for nat in ec2.describe_nat_gateways(Filter=[{"Name": "state", "Values": ["pending", "available"]}])["NatGateways"]:
        if _is_bss(_tags(nat.get("Tags"))):
            out.append(Orphan("NAT Gateway", nat["NatGatewayId"], "~$1.10/ngày + phí dữ liệu"))
    for addr in ec2.describe_addresses()["Addresses"]:
        if "AssociationId" not in addr and _is_bss(_tags(addr.get("Tags"))):
            out.append(Orphan("Elastic IP", addr.get("PublicIp", "?"), "không gắn vào đâu — vẫn tính phí IPv4"))
    for page in ec2.get_paginator("describe_volumes").paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        for vol in page["Volumes"]:
            if _is_bss(_tags(vol.get("Tags"))):
                out.append(Orphan("EBS volume", vol["VolumeId"], f"{vol['Size']} GiB {vol['VolumeType']} không gắn"))
    for page in ec2.get_paginator("describe_network_interfaces").paginate(
        Filters=[{"Name": "status", "Values": ["available"]}]
    ):
        for eni in page["NetworkInterfaces"]:
            if _is_bss(_tags(eni.get("TagSet"))) or eni.get("Description", "").startswith(("aws-K8S", "Amazon EKS " + PREFIX)):
                out.append(Orphan("ENI", eni["NetworkInterfaceId"], eni.get("Description", "")[:60]))
    # Không tính tiền, nhưng CHẶN xóa VPC (lỗi thật 2026-09-30: SG `eks-cluster-sg-*` sót lại vì 1 ENI của
    # VPC CNI còn giữ nó khi cluster bị xóa). Chỉ báo SG của cluster bss-* KHÔNG còn tồn tại.
    # Nhận diện theo TÊN EKS đặt (`eks-cluster-sg-<cluster>-<số>`) — tag `aws:eks:cluster-name` chỉ dịch vụ AWS
    # gắn được, không tái hiện được khi kiểm thử (xem teardown.sh cleanup_vpc_leftovers).
    for page in ec2.get_paginator("describe_security_groups").paginate(
        Filters=[{"Name": "group-name", "Values": [f"eks-cluster-sg-{PREFIX}*"]}]
    ):
        for sg in page["SecurityGroups"]:
            cluster = sg["GroupName"][len("eks-cluster-sg-"):].rsplit("-", 1)[0]
            if cluster not in live_clusters:
                out.append(Orphan("Security group", sg["GroupId"], f"của cluster đã xóa {cluster} — chặn xóa VPC"))
    for vpc in ec2.describe_vpcs()["Vpcs"]:
        tags = _tags(vpc.get("Tags"))
        if _is_bss(tags, tags.get("Name", "")):
            out.append(Orphan("VPC", vpc["VpcId"], tags.get("Name", "") + " — destroy chưa xong hoặc bị chặn"))
    return out


def find_elb(elbv2) -> list[Orphan]:
    out: list[Orphan] = []
    lbs = elbv2.describe_load_balancers()["LoadBalancers"]
    arns = [lb["LoadBalancerArn"] for lb in lbs]
    tag_map: dict[str, dict[str, str]] = {}
    for i in range(0, len(arns), 20):  # describe_tags nhận tối đa 20 ARN
        for d in elbv2.describe_tags(ResourceArns=arns[i : i + 20])["TagDescriptions"]:
            tag_map[d["ResourceArn"]] = _tags(d["Tags"])
    for lb in lbs:
        if _is_bss(tag_map.get(lb["LoadBalancerArn"], {}), lb["LoadBalancerName"]) or lb["LoadBalancerName"].startswith("k8s-bss"):
            out.append(Orphan("Load Balancer", lb["LoadBalancerName"], f"{lb['Type']} — do Ingress tạo, không nằm trong state"))
    for tg in elbv2.describe_target_groups()["TargetGroups"]:
        if not tg.get("LoadBalancerArns") and tg["TargetGroupName"].startswith("k8s-bss"):
            out.append(Orphan("Target Group", tg["TargetGroupName"], "không gắn ALB nào"))
    return out


def find_eks_rds(eks, rds) -> list[Orphan]:
    out: list[Orphan] = []
    for name in eks.list_clusters()["clusters"]:
        if name.startswith(PREFIX):
            out.append(Orphan("EKS cluster", name, "~$0.10/giờ control plane + node"))
    for db in rds.describe_db_instances()["DBInstances"]:
        if db["DBInstanceIdentifier"].startswith(PREFIX):
            out.append(Orphan("RDS instance", db["DBInstanceIdentifier"], f"{db['DBInstanceClass']} {db['DBInstanceStatus']}"))
    for snap in rds.describe_db_snapshots(SnapshotType="manual")["DBSnapshots"]:
        if snap["DBSnapshotIdentifier"].startswith(PREFIX):
            out.append(Orphan("RDS snapshot", snap["DBSnapshotIdentifier"], f"{snap.get('AllocatedStorage', '?')} GiB — tính phí lưu trữ"))
    return out


def find_dns(route53, live_clusters: set[str]) -> list[Orphan]:
    """B-23 / ADR-012: zone Route 53 sống ở `shared` (CỐ Ý lâu dài), nhưng bản ghi trong đó do ExternalDNS
    của TỪNG cluster tạo. Cluster bị destroy trước khi ExternalDNS kịp xóa (teardown.sh chờ việc này) → bản
    ghi alias trỏ vào ALB đã chết ("dangling"). Không tính tiền, nhưng tên miền hỏng/treo cho tới khi xóa.
    Nhận diện qua bản ghi TXT "sở hữu" ExternalDNS ghi cạnh mỗi bản ghi: `external-dns/owner=<cluster>`."""
    out: list[Orphan] = []
    for page in route53.get_paginator("list_hosted_zones").paginate():
        for zone in page["HostedZones"]:
            zone_id = zone["Id"].rsplit("/", 1)[-1]
            tags = _tags(route53.list_tags_for_resource(ResourceType="hostedzone", ResourceId=zone_id)["ResourceTagSet"].get("Tags"))
            if not _is_bss(tags):
                continue
            for rpage in route53.get_paginator("list_resource_record_sets").paginate(HostedZoneId=zone["Id"]):
                for rr in rpage["ResourceRecordSets"]:
                    if rr["Type"] != "TXT":
                        continue
                    for rec in rr.get("ResourceRecords", []):
                        owner = next((kv.split("=", 1)[1] for kv in rec["Value"].strip('"').split(",")
                                      if kv.startswith("external-dns/owner=")), None)
                        if owner and owner.startswith(PREFIX) and owner not in live_clusters:
                            out.append(Orphan("DNS record", rr["Name"].rstrip("."), f"của cluster đã xóa {owner} — trỏ vào ALB không còn"))
    return out


def find_all(session: boto3.session.Session) -> list[Orphan]:
    ec2 = session.client("ec2")
    eks = session.client("eks")
    live_clusters = set(eks.list_clusters()["clusters"])
    return (
        find_eks_rds(eks, session.client("rds"))
        + find_ec2(ec2)
        + find_elb(session.client("elbv2"))
        + find_nat_eip_ebs_eni(ec2, live_clusters)
        + find_dns(session.client("route53"), live_clusters)
    )


def main() -> int:
    # Console Windows (cp1252) không in được "✓/✗" + tiếng Việt → UnicodeEncodeError (lỗi thật 2026-09-30 —
    # 3 script ops kia đã sửa ở GĐ8, script này bị sót). teardown.sh có đặt PYTHONIOENCODING, gọi tay thì không.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--profile", default=None, help="AWS CLI profile name")
    parser.add_argument("--json", action="store_true", help="In JSON thay vì bảng")
    args = parser.parse_args()

    try:
        orphans = find_all(boto3.session.Session(profile_name=args.profile, region_name=args.region))
    except (BotoCoreError, ClientError) as exc:
        print(f"orphan_finder: lỗi gọi AWS — {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps([asdict(o) for o in orphans], ensure_ascii=False, indent=2))
    elif not orphans:
        print(f"✓ Không còn tài nguyên BSS tính tiền nào ở {args.region}.")
    else:
        print(f"✗ {len(orphans)} tài nguyên BSS còn sót ở {args.region}:")
        for o in orphans:
            print(f"  {o.kind:<14} {o.id:<45} {o.detail}")
    return 1 if orphans else 0


if __name__ == "__main__":
    sys.exit(main())

terraform {

  cloud {
    organization = "malaysia-ai"

    workspaces {
      name = "infra"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.16.0"
    }
  }

  required_version = ">= 1.1.0"
}

provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}


data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "controlplane" {
  name               = "eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "controlplane_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.controlplane.name
}

resource "aws_default_vpc" "default" {
}

resource "aws_default_subnet" "subnet1" {
  availability_zone = "ap-southeast-1a"
}

resource "aws_default_subnet" "subnet2" {
  availability_zone = "ap-southeast-1b"
}

resource "aws_default_subnet" "subnet3" {
  availability_zone = "ap-southeast-1c"
}


resource "aws_eks_cluster" "cluster" {
  name     = "deployment"
  role_arn = aws_iam_role.controlplane.arn

  vpc_config {
    subnet_ids = [aws_default_subnet.subnet1.id, aws_default_subnet.subnet2.id, aws_default_subnet.subnet3.id]
  }

  version = "1.26"
}

resource "aws_iam_role" "nodegroup" {
  name = "eks-nodegroup"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "nodegroup_attachment-worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.nodegroup.name
}

resource "aws_iam_role_policy_attachment" "nodegroup_attachment-cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.nodegroup.name
}

resource "aws_iam_role_policy_attachment" "nodegroup_attachment-ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.nodegroup.name
}

resource "aws_eks_node_group" "node1" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "node1"
  node_role_arn   = aws_iam_role.nodegroup.arn
  subnet_ids      = [aws_default_subnet.subnet1.id, aws_default_subnet.subnet2.id, aws_default_subnet.subnet3.id]

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

  capacity_type = "SPOT"

}


resource "aws_eks_node_group" "node2" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "node2"
  node_role_arn   = aws_iam_role.nodegroup.arn
  subnet_ids      = [aws_default_subnet.subnet1.id, aws_default_subnet.subnet2.id, aws_default_subnet.subnet3.id]

  scaling_config {
    desired_size = 2 
    max_size     = 2  
    min_size     = 2  
  }

  instance_types = ["t3.xlarge"]
  capacity_type = "SPOT"
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list = ["sts.amazonaws.com"]
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
  # https://github.com/terraform-providers/terraform-provider-tls/issues/52
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
  url             = aws_eks_cluster.cluster.identity.0.oidc.0.issuer
}

data "aws_iam_policy_document" "ebs_cni_controller" {
  statement {
    sid = "EBSCNIAssumeRole"

    actions = [
      "sts:AssumeRoleWithWebIdentity",
    ]

    principals {
      identifiers = [aws_iam_openid_connect_provider.this.arn]
      type        = "Federated"
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_cni" {
  name               = "AmazonEKS_EBS_CSI_DriverRole_Data"
  assume_role_policy = data.aws_iam_policy_document.ebs_cni_controller.json

  # tags = module.main.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_cni.name
}

resource "aws_eks_addon" "csi_driver" {
  cluster_name             = aws_eks_cluster.cluster.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_cni.arn
}

resource "aws_acm_certificate" "cert" {
  domain_name       = "gpu.peacehotel.my"
  subject_alternative_names = ["*.gpu.peacehotel.my"]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "mesolitica" {
  domain_name       = "aws.mesolitica.com"
  subject_alternative_names = ["*.aws.mesolitica.com"]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# https://github.com/bootlabstech/terraform-aws-fully-loaded-eks-cluster/tree/v1.0.7/modules/kubernetes-addons/airflow

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.cluster.certificate_authority.0.data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.cluster.name, "--region", var.region]
      command     = "aws"
      env = {
        "AWS_ACCESS_KEY_ID" = var.aws_access_key,
        "AWS_SECRET_ACCESS_KEY" = var.aws_secret_key
    }
    }
  }
}

resource "helm_release" "nginx" {
  depends_on = [aws_eks_cluster.cluster]
  name       = "nginx"

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert"
    value = aws_acm_certificate.mesolitica.arn
    type  = "string"
  }

  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-backend-protocol"
    value = "tcp"
  }

  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-ports"
    value = "https"

  }

  set {
    name = "controller.service.targetPorts.https"
    value = "http"
  }

  set {
    name = "controller.config.use-forwarded-headers"
    value = "true"
  }

  set {
    name = "controller.config.proxy-real-ip-cidr"
    value = aws_default_vpc.default.cidr_block
    type  = "string"
  }
}

# resource "helm_release" "rancher" {
#   depends_on = [aws_eks_cluster.cluster]
#   name       = "rancher"
  
#   repository = "https://releases.rancher.com/server-charts/latest"
#   chart      = "rancher"
#   namespace  = "cattle-system"
#   create_namespace = true
#   force_update = true

#   set {
#     name  = "hostname"
#     value = "rancher.aws.mesolitica.com"
#   }

#   set {
#     name  = "replicas"
#     value = "1"
#   }

#   set {
#     name  = "bootstrapPassword"
#     value = var.rancher_password
#   }

#   set {
#     name = "global.cattle.psp.enabled"
#     value = "false"
#   }

#   set {
#     name = "tls"
#     value = "external"
#   }

#   set {
#     name = "ingress.extraAnnotations\\.kubernetes\\.io/ingress\\.class"
#     value = "nginx"
#   }
# }
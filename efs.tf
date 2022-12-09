data "aws_availability_zones" "available" {}

resource "aws_efs_file_system" "efs" {
  creation_token   = "efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = "true"
  tags = {
    Name = var.efs_name
  }
}



resource "aws_efs_mount_target" "efs_target" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = element(module.vpc.public_subnets, count.index)
  security_groups = [aws_security_group.xac_airflow_efs_sg.id]
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group
# EFS SG
resource "aws_security_group" "xac_airflow_efs_sg" {
  name        = "xac_airflow_efs"
  description = "Allows inbound efs traffic from EKS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 2049
    to_port   = 2049
    protocol  = "tcp"
    #cidr_blocks = [module.vpc.vpc_cidr_block]
    # 192.168 included for development
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  # fix from https://github.com/aws-samples/aws-eks-accelerator-for-terraform/commit/e6b364d87221eb481d8e93b08bb9597c1e22bf3e
  #
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    #cidr_blocks = [module.vpc.vpc_cidr_block]
    # 192.168 included for development
    cidr_blocks = [module.vpc.vpc_cidr_block]
    #cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  tags = local.tags
}

###############################################################################
# Create an IAM policy and role
###############################################################################
# based on https://github.com/DNXLabs/terraform-aws-eks-efs-csi-driver/blob/master/iam.tf

data "aws_iam_policy_document" "efs_csi_driver" {
  statement {
    actions = [
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:DescribeMountTargets",
      "ec2:DescribeAvailabilityZones"
    ]
    resources = ["*"]
    effect    = "Allow"
  }

  statement {
    actions = [
      "elasticfilesystem:CreateAccessPoint"
    ]
    resources = ["*"]
    effect    = "Allow"
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/efs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }

  statement {
    actions = [
      "elasticfilesystem:DeleteAccessPoint"
    ]
    resources = ["*"]
    effect    = "Allow"
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/efs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }
}

# create policy
resource "aws_iam_policy" "eks_efs_driver_policy" {
  name        = "xac-efs-csi-driver-policy"
  description = "allow EKS access to EFS"
  policy      = data.aws_iam_policy_document.efs_csi_driver.json
}

# create role
resource "aws_iam_role" "eks_efs_driver_role" {
  depends_on         = [module.eks]
  name               = "xac-efs-csi-driver-role"
  assume_role_policy = <<-EOF
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "${module.eks.oidc_provider_arn}"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "oidc.eks.${var.aws_region}.amazonaws.com/id/${basename(module.eks.oidc_provider_arn)}:sub": "system:serviceaccount:kube-system:aws-efs-csi-driver-sa"
           }
         }
       }
     ]
   }
   EOF
}

resource "aws_iam_policy_attachment" "eks_efs_driver_attach" {
  name       = "eks_efs_driver_attach"
  roles      = ["${aws_iam_role.eks_efs_driver_role.name}"]
  policy_arn = aws_iam_policy.eks_efs_driver_policy.arn
}



###############################################################################
# Install the Amazon EFS driver
###############################################################################
# modified from https://github.com/DNXLabs/terraform-aws-eks-efs-csi-driver

resource "helm_release" "efs_csi_driver" {

  name = "efs-csi-driver"

  namespace       = "kube-system"
  cleanup_on_fail = true
  force_update    = false

  chart = "https://github.com/kubernetes-sigs/aws-efs-csi-driver/releases/download/helm-chart-aws-efs-csi-driver-2.2.7/aws-efs-csi-driver-2.2.7.tgz"

  set {
    name  = "image.repository"
    value = "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/aws-efs-csi-driver"
  }

  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.serviceAccount.name"
    value = "aws-efs-csi-driver-sa"
  }

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eks_efs_driver_role.arn #kubernetes_service_account.efs_csi_driver.metadata.0.name
  }

  set {
    name  = "node.serviceAccount.create"
    value = "false"
  }

  set {
    name  = "node.serviceAccount.name"
    value = "aws-efs-csi-driver-sa"
  }

  set {
    name  = "node.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eks_efs_driver_role.arn
  }

  depends_on = [
    aws_efs_mount_target.efs_target
  ]

}

resource "kubernetes_storage_class_v1" "efs_storage_class" {

  metadata {
    name = "efs-sc"
  }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "Immediate"
  parameters = {
    "provisioningMode" = "efs-ap"
    "fileSystemId"     = aws_efs_file_system.efs.id
    "directoryPerms"   = "755"
    "uid"              = "1000"
    "gid"              = "1000"
    "basePath"         = "/dynamic_provisioning"
  }

  depends_on = [
    helm_release.efs_csi_driver
  ]

}
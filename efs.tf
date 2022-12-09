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
  security_groups = [aws_security_group.efs_sg.id]
}


# EFS SG
resource "aws_security_group" "efs_sg" {
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
    aws_efs_mount_target.efs_target, module.eks
  ]

}

resource "kubernetes_storage_class_v1" "efs_sc" {
  metadata {
    name = "efs-sc"
  }
  storage_provisioner = "efs.csi.aws.com"
  depends_on = [
    aws_efs_mount_target.efs_target
  ]
}

resource "kubernetes_persistent_volume_v1" "efs_pv" {
  metadata {
    name = "efs-pv"
  }
  spec {
    capacity = {
      storage = "5Gi"
    }
    volume_mode                      = "Filesystem"
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class_v1.efs_sc.metadata[0].name
    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = aws_efs_file_system.efs.id
      }
    }
  }
  depends_on = [
    aws_efs_mount_target.efs_target
  ]
}


resource "kubernetes_persistent_volume_claim_v1" "efs_pvc" {
  metadata {
    name = "efs-claim"
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.efs_sc.metadata[0].name
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
  depends_on = [
    aws_efs_mount_target.efs_target
  ]
}
data "aws_eks_cluster" "eks-cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "eks-cluster" {
  name = module.eks.cluster_id
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {}
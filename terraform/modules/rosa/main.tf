data "aws_caller_identity" "rosa" {}
data "aws_partition" "current" {}

data "rhcs_info" "current" {}
data "rhcs_hcp_policies" "all" {}

locals {
  rosa_managed_policies = {
    installer = data.rhcs_hcp_policies.all.account_role_policies.sts_hcp_installer_permission_policy
    support   = data.rhcs_hcp_policies.all.account_role_policies.sts_hcp_support_permission_policy
    worker    = data.rhcs_hcp_policies.all.account_role_policies.sts_hcp_instance_worker_permission_policy
  }

  rosa_installer_role_arn = "arn:aws:iam::${data.rhcs_info.current.ocm_aws_account_id}:role/RH-Managed-OpenShift-Installer"
  rosa_support_role_arn   = data.rhcs_hcp_policies.all.account_role_policies.sts_support_rh_sre_role

  rosa_role_type_tags = {
    installer = "installer"
    support   = "support"
    worker    = "instance_worker"
  }

  rosa_role_name_suffix = {
    installer = "HCP-ROSA-Installer-Role"
    support   = "HCP-ROSA-Support-Role"
    worker    = "HCP-ROSA-Worker-Role"
  }

  rosa_operator_role_templates = [
    {
      operator_name      = "installer-cloud-credentials"
      operator_namespace = "openshift-image-registry"
      role_name_suffix   = "openshift-image-registry-installer-cloud-credentials"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_image_registry_installer_cloud_credentials_policy
      service_accounts = [
        "system:serviceaccount:openshift-image-registry:cluster-image-registry-operator",
        "system:serviceaccount:openshift-image-registry:registry",
      ]
    },
    {
      operator_name      = "cloud-credentials"
      operator_namespace = "openshift-ingress-operator"
      role_name_suffix   = "openshift-ingress-operator-cloud-credentials"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_ingress_operator_cloud_credentials_policy
      service_accounts   = ["system:serviceaccount:openshift-ingress-operator:ingress-operator"]
    },
    {
      operator_name      = "ebs-cloud-credentials"
      operator_namespace = "openshift-cluster-csi-drivers"
      role_name_suffix   = "openshift-cluster-csi-drivers-ebs-cloud-credentials"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_cluster_csi_drivers_ebs_cloud_credentials_policy
      service_accounts = [
        "system:serviceaccount:openshift-cluster-csi-drivers:aws-ebs-csi-driver-operator",
        "system:serviceaccount:openshift-cluster-csi-drivers:aws-ebs-csi-driver-controller-sa",
      ]
    },
    {
      operator_name      = "cloud-credentials"
      operator_namespace = "openshift-cloud-network-config-controller"
      role_name_suffix   = "openshift-cloud-network-config-controller-cloud-credentials"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_cloud_network_config_controller_cloud_credentials_policy
      service_accounts   = ["system:serviceaccount:openshift-cloud-network-config-controller:cloud-network-config-controller"]
    },
    {
      operator_name      = "kube-controller-manager"
      operator_namespace = "kube-system"
      role_name_suffix   = "kube-system-kube-controller-manager"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_kube_controller_manager_credentials_policy
      service_accounts   = ["system:serviceaccount:kube-system:kube-controller-manager"]
    },
    {
      operator_name      = "capa-controller-manager"
      operator_namespace = "kube-system"
      role_name_suffix   = "kube-system-capa-controller-manager"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_capa_controller_manager_credentials_policy
      service_accounts   = ["system:serviceaccount:kube-system:capa-controller-manager"]
    },
    {
      operator_name      = "control-plane-operator"
      operator_namespace = "kube-system"
      role_name_suffix   = "kube-system-control-plane-operator"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_control_plane_operator_credentials_policy
      service_accounts   = ["system:serviceaccount:kube-system:control-plane-operator"]
    },
    {
      operator_name      = "kms-provider"
      operator_namespace = "kube-system"
      role_name_suffix   = "kube-system-kms-provider"
      policy_arn         = data.rhcs_hcp_policies.all.operator_role_policies.openshift_hcp_kms_provider_credentials_policy
      service_accounts   = ["system:serviceaccount:kube-system:kms-provider"]
    },
  ]

  rosa_account_roles = merge([
    for cluster_name, cluster in var.rosa_clusters : {
      for role_type in ["installer", "support", "worker"] :
      "${cluster_name}-${role_type}" => {
        cluster_name = cluster_name
        role_type    = role_type
        prefix       = cluster.rosa.operatorRolePrefix
      }
    }
  ]...)

  rosa_operator_roles = merge([
    for cluster_name, cluster in var.rosa_clusters : {
      for template in local.rosa_operator_role_templates :
      "${cluster_name}-${template.role_name_suffix}" => {
        cluster_name        = cluster_name
        role_name           = substr("${cluster.rosa.operatorRolePrefix}-${template.role_name_suffix}", 0, 64)
        operator_name       = template.operator_name
        operator_namespace  = template.operator_namespace
        service_accounts    = template.service_accounts
        policy_arn          = template.policy_arn
        operator_role_prefix = cluster.rosa.operatorRolePrefix
        oidc_endpoint_url   = cluster.rosa.createOidc ? rhcs_rosa_oidc_config.rosa_oidc[cluster_name].oidc_endpoint_url : try(cluster.rosa.oidcEndpointUrl, "")
      }
    }
  ]...)
}

data "aws_iam_policy_document" "rosa_assume_role_worker" {
  for_each = {
    for key, role in local.rosa_account_roles : key => role
    if role.role_type == "worker"
  }

  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "rosa_assume_role_ocm" {
  for_each = {
    for key, role in local.rosa_account_roles : key => role
    if role.role_type == "installer" || role.role_type == "support"
  }

  statement {
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = (
        each.value.role_type == "installer"
        ? [local.rosa_installer_role_arn]
        : [local.rosa_support_role_arn]
      )
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "rosa_account_roles" {
  for_each = local.rosa_account_roles
  name     = "${each.value.prefix}-${local.rosa_role_name_suffix[each.value.role_type]}"

  assume_role_policy = (
    each.value.role_type == "worker"
    ? data.aws_iam_policy_document.rosa_assume_role_worker[each.key].json
    : data.aws_iam_policy_document.rosa_assume_role_ocm[each.key].json
  )

  tags = {
    red-hat-managed       = true
    rosa_hcp_policies     = true
    rosa_managed_policies = true
    rosa_role_prefix      = each.value.prefix
    rosa_role_type        = local.rosa_role_type_tags[each.value.role_type]
  }
}

resource "aws_iam_role_policy_attachment" "rosa_account_roles" {
  for_each   = local.rosa_account_roles
  role       = aws_iam_role.rosa_account_roles[each.key].name
  policy_arn = local.rosa_managed_policies[each.value.role_type]
}

data "aws_iam_policy_document" "rosa_assume_operator_roles" {
  for_each = local.rosa_operator_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.rosa.account_id}:oidc-provider/${replace(each.value.oidc_endpoint_url, "https://", "")}",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(each.value.oidc_endpoint_url, "https://", "")}:sub"
      values   = each.value.service_accounts
    }
  }
}

resource "aws_iam_role" "rosa_operator_roles" {
  for_each = local.rosa_operator_roles

  name = each.value.role_name

  assume_role_policy = data.aws_iam_policy_document.rosa_assume_operator_roles[each.key].json

  tags = {
    red-hat-managed       = true
    rosa_hcp_policies     = true
    rosa_managed_policies = true
    operator_namespace    = each.value.operator_namespace
    operator_name         = each.value.operator_name
  }
}

resource "aws_iam_role_policy_attachment" "rosa_operator_roles" {
  for_each = local.rosa_operator_roles

  role       = aws_iam_role.rosa_operator_roles[each.key].name
  policy_arn = each.value.policy_arn
}

resource "rhcs_rosa_oidc_config" "rosa_oidc" {
  for_each = { for k, v in var.rosa_clusters : k => v if v.rosa.createOidc }
  managed  = true
}

resource "aws_iam_openid_connect_provider" "rosa_oidc" {
  for_each = { for k, v in var.rosa_clusters : k => v if v.rosa.createOidc }

  url             = rhcs_rosa_oidc_config.rosa_oidc[each.key].issuer_url
  client_id_list  = ["openshift", "sts.amazonaws.com"]
  thumbprint_list = [rhcs_rosa_oidc_config.rosa_oidc[each.key].thumbprint]

  tags = {
    red-hat-managed   = true
    rosa_cluster_name = each.key
  }
}

resource "rhcs_cluster_rosa_hcp" "rosa_clusters" {
  for_each = var.rosa_clusters

  depends_on = [aws_iam_role_policy_attachment.rosa_operator_roles]

  name                   = each.key
  cloud_region           = lookup(each.value, "region", var.region)
  aws_account_id         = data.aws_caller_identity.rosa.account_id
  aws_billing_account_id = data.aws_caller_identity.rosa.account_id
  version                = each.value.version
  compute_machine_type   = each.value.machineType
  replicas               = each.value.replicas
  private                = each.value.private

  machine_cidr = each.value.network.machineCIDR

  aws_subnet_ids = concat(
    [for s in each.value.network.publicSubnetRefs : var.subnets[s].id],
    [for s in each.value.network.privateSubnetRefs : var.subnets[s].id]
  )

  availability_zones = distinct(concat(
    [for s in each.value.network.publicSubnetRefs : var.subnets[s].availability_zone],
    [for s in each.value.network.privateSubnetRefs : var.subnets[s].availability_zone]
  ))

  sts = {
    role_arn         = aws_iam_role.rosa_account_roles["${each.key}-installer"].arn
    support_role_arn = aws_iam_role.rosa_account_roles["${each.key}-support"].arn
    instance_iam_roles = {
      worker_role_arn = aws_iam_role.rosa_account_roles["${each.key}-worker"].arn
    }
    operator_role_prefix = each.value.rosa.operatorRolePrefix
    oidc_config_id       = each.value.rosa.createOidc ? rhcs_rosa_oidc_config.rosa_oidc[each.key].id : each.value.rosa.oidcId
  }

  properties = {
    rosa_creator_arn = data.aws_caller_identity.rosa.arn
  }

  lifecycle {
    ignore_changes = [version]
  }
}

resource "rhcs_cluster_wait" "rosa_clusters" {
  for_each = var.rosa_clusters
  cluster  = rhcs_cluster_rosa_hcp.rosa_clusters[each.key].id
  timeout  = 60
}

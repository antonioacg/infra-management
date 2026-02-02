# NetworkPolicies for storage and databases namespaces
# Purpose: Default-deny policies with explicit allow rules for required traffic

# Storage namespace (MinIO) - default deny
resource "kubernetes_network_policy" "storage_default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = "storage"
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
  depends_on = [kubernetes_namespace.storage]
}

# MinIO server policy
resource "kubernetes_network_policy" "minio_server" {
  metadata {
    name      = "minio-server"
    namespace = "storage"
  }
  spec {
    pod_selector {
      match_labels = { app = "minio" }
    }
    policy_types = ["Ingress", "Egress"]

    # From Vault
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "vault" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "vault" }
        }
      }
      ports { protocol = "TCP"
        port = "9000" }
    }
    # From tf-controller
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "flux-system" }
        }
      }
      ports { protocol = "TCP"
        port = "9000" }
    }
    # DNS only
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports { protocol = "UDP"
        port = "53" }
      ports { protocol = "TCP"
        port = "53" }
    }
  }
  depends_on = [kubernetes_namespace.storage, helm_release.minio]
}

# Databases namespace - default deny
resource "kubernetes_network_policy" "databases_default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = "databases"
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
  depends_on = [kubernetes_namespace.databases]
}

# PostgreSQL cluster policy
resource "kubernetes_network_policy" "postgresql_cluster" {
  metadata {
    name      = "postgresql-cluster"
    namespace = "databases"
  }
  spec {
    pod_selector {
      match_labels = { "postgresql.cnpg.io/cluster" = "postgresql" }
    }
    policy_types = ["Ingress", "Egress"]

    # From tf-controller
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "flux-system" }
        }
      }
      ports { protocol = "TCP"
        port = "5432" }
    }
    # From CNPG operator
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "cnpg-system" }
        }
      }
      ports { protocol = "TCP"
        port = "5432" }
      ports { protocol = "TCP"
        port = "8000" }
    }
    # PostgreSQL replication
    ingress {
      from {
        pod_selector {
          match_labels = { "postgresql.cnpg.io/cluster" = "postgresql" }
        }
      }
      ports { protocol = "TCP"
        port = "5432" }
    }
    # DNS
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports { protocol = "UDP"
        port = "53" }
      ports { protocol = "TCP"
        port = "53" }
    }
    # Replication egress
    egress {
      to {
        pod_selector {
          match_labels = { "postgresql.cnpg.io/cluster" = "postgresql" }
        }
      }
      ports { protocol = "TCP"
        port = "5432" }
    }
  }
  depends_on = [kubernetes_namespace.databases, null_resource.postgresql]
}

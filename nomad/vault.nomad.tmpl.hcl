job "vault" {
  datacenters = ["dc1"]
  type        = "service"

  group "vault" {
    network {
      port "http" {
        static = 18200
        to     = 8200
      }
    }

    task "vault" {
      driver = "docker"

      config {
        image = "hashicorp/vault-enterprise:1.21.2-ent"
        args = [
          "server",
        ]
        volumes = [
          "vault-data:/vault/data",
        ]
        ports = ["http"]
      }

      env {
        VAULT_ADDR              = "http://127.0.0.1:8200"
        VAULT_LICENSE           = "__LAB_VAULT_LICENSE__"
        VAULT_LOCAL_CONFIG      = "__LAB_VAULT_LOCAL_CONFIG__"
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}

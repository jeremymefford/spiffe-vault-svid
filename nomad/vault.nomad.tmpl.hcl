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
        image = "hashicorp/vault:1.18.3"
        args = [
          "server",
          "-dev",
          "-dev-root-token-id=__LAB_VAULT_DEV_ROOT_TOKEN__",
          "-dev-listen-address=0.0.0.0:8200",
        ]
        ports = ["http"]
      }

      env {
        VAULT_DEV_ROOT_TOKEN_ID = "__LAB_VAULT_DEV_ROOT_TOKEN__"
        VAULT_ADDR              = "http://127.0.0.1:8200"
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}

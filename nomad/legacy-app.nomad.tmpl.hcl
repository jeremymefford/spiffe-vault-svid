job "legacy-app" {
  datacenters = ["dc1"]
  type        = "batch"

  group "legacy-app" {
    restart {
      attempts = 0
      mode     = "fail"
    }

    task "legacy-app" {
      driver = "docker"

      config {
        image = "__LAB_LEGACY_IMAGE__"
        force_pull = false
      }

      env {
        LAB_VAULT_ADDR       = "__LAB_VAULT_ADDR_NOMAD__"
        LAB_VAULT_ROLE_ID    = "__LAB_VAULT_ROLE_ID__"
        LAB_VAULT_SECRET_ID  = "__LAB_VAULT_SECRET_ID__"
        LAB_LEGACY_SPIFFE_ID = "__LAB_LEGACY_SPIFFE_ID__"
        LAB_MODERN_URL       = "__LAB_MODERN_URL_NOMAD__"
        LAB_MODERN_ROOT_CA_PEM = "__LAB_MODERN_ROOT_CA_PEM__"
        LAB_KEYSTORE_PASSWORD = "__LAB_KEYSTORE_PASSWORD__"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}

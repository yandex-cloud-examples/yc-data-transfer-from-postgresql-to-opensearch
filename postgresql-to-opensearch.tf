# Infrastructure for the Yandex Managed Service for OpenSearch, Managed Service for PostgreSQL, and Data Transfer
#
# RU: https://cloud.yandex.ru/ru/docs/data-transfer/tutorials/postgresql-to-opensearch
# EN: https://cloud.yandex.ru/en/docs/data-transfer/tutorials/postgresql-to-opensearch
#
# Configure the parameters of the source claster, target cluster and transfer:

locals {
  folder_id    = "" # Your cloud folder ID, same as for provider
  mos_version  = "" # Desired version of the OpenSearch. For available versions, see the documentation main page: https://yandex.cloud/en/docs/managed-opensearch/.
  mos_password = "" # OpenSearch admin's password
  pg_password  = "" # PostgreSQL admin's password

  # Specify these settings ONLY AFTER the clusters are created. Then run the "terraform apply" command again.
  # You should set up the endpoint using the GUI to obtain its ID
  target_endpoint_id = "" # Set the target endpoint ID
  transfer_enabled   = 0  # Set to 1 to create transfer

  # Setting for the YC CLI that allows running CLI command to activate the transfer
  profile_name = "" # Name of the YC CLI profile

  # The following settings are predefined. Change them only if necessary.
  network_name        = "network"                           # Name of the network
  subnet_name         = "subnet-a"                          # Name of the subnet
  security_group_name = "security-group"                    # Name of the security group
  mos_cluster_name    = "opensearch-cluster"                # Name of the OpenSearch cluster
  mpg_cluster_name    = "mpg-cluster"                       # Name of the PostgreSQL cluster
  transfer_name       = "postgresql-to-opensearch-transfer" # Name of the transfer from the Managed Service for PostgreSQL database to the OpenSearch cluster
}

resource "yandex_vpc_network" "network" {
  description = "Network for Managed Service for PostgreSQL"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet ru-central1-a availability zone for PostgreSQL"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.129.0.0/24"]
}

resource "yandex_vpc_security_group" "security-group" {
  description = "Security group for the Managed Service for PostgreSQL and Opensearch clusters"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allows incoming traffic on port 6432"
    protocol       = "TCP"
    port           = 6432
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allows incoming traffic on port 443"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allows incoming traffic on port 9200"
    protocol       = "TCP"
    port           = 9200
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allows all outgoing traffic"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create PostgreSQL cluster

resource "yandex_mdb_postgresql_user" "pg-user" {
  cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
  name       = "pg-user"
  password   = local.pg_password
}

resource "yandex_mdb_postgresql_database" "mpg-db" {
  cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
  name       = "db1"
  owner      = yandex_mdb_postgresql_user.pg-user.name
  depends_on = [
    yandex_mdb_postgresql_user.pg-user
  ]
}

resource "yandex_mdb_postgresql_cluster" "mpg-cluster" {
  description        = "Managed PostgreSQL cluster"
  name               = "mpg-cluster"
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.security-group.id]

  config {
    version = 14
    resources {
      resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
      disk_type_id       = "network-ssd"
      disk_size          = "20" # GB
    }
  }

  host {
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.subnet-a.id
    assign_public_ip = true
  }
}

# Create OpenSearch cluster

resource "yandex_mdb_opensearch_cluster" "opensearch-cluster" {
  description        = "Managed Service for OpenSearch cluster"
  name               = local.mos_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.security-group.id]

  config {

    version        = local.mos_version
    admin_password = local.mos_password

    opensearch {
      node_groups {
        name             = "opensearch-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        subnet_ids       = [yandex_vpc_subnet.subnet-a.id]
        roles            = ["DATA", "MANAGER"]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }
    }

    dashboards {
      node_groups {
        name             = "dashboards-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        subnet_ids       = [yandex_vpc_subnet.subnet-a.id]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }
    }
  }

  maintenance_window {
    type = "ANYTIME"
  }
}

resource "yandex_datatransfer_endpoint" "mpg-source" {
  description = "Source endpoint for PostgreSQL cluster"
  name        = "mpg-source"
  settings {
    postgres_source {
      connection {
        mdb_cluster_id = yandex_mdb_postgresql_cluster.mpg-cluster.id
      }
      database = "db1"
      user     = "pg-user"
      password {
        raw = local.pg_password
      }
    }
  }
}

# Create transfer
resource "yandex_datatransfer_transfer" "postgresql-to-opensearch-transfer" {
  count       = local.transfer_enabled
  description = "Transfer from the PostgreSQL database to the OpenSearch cluster"
  name        = "postgresql-to-opensearch-transfer"
  target_id   = local.target_endpoint_id
  source_id   = yandex_datatransfer_endpoint.mpg-source.id
  type        = "SNAPSHOT_ONLY" # Copy data from the source PostgreSQL database

  provisioner "local-exec" {
    command = "yc --profile ${local.profile_name} datatransfer transfer activate ${yandex_datatransfer_transfer.postgresql-to-opensearch-transfer[count.index].id}"
  }
}
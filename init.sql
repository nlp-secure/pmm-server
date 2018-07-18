ALTER USER 'root'@'localhost' IDENTIFIED BY '45!AvYZjd9xG';

CREATE DATABASE IF NOT EXISTS orchestrator;
GRANT ALL PRIVILEGES ON orchestrator.* TO 'orchestrator'@'localhost' IDENTIFIED BY 'orchestrator';

CREATE DATABASE IF NOT EXISTS `pmm-managed`;
GRANT ALL PRIVILEGES ON `pmm-managed`.* TO "pmm-managed"@localhost IDENTIFIED BY "pmm-managed";

GRANT SELECT ON pmm.* TO 'grafana'@'localhost' IDENTIFIED BY 'N9mutoipdtlxutgi9rHIFnjM'
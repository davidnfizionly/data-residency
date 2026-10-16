package terraform.residency_test

import rego.v1

import data.terraform.residency

registry(eu_storage) := json.marshal({
	"synthetic-eu-01": {"tenant_region": "eu-west-1", "storage_region": eu_storage},
	"synthetic-us-01": {"tenant_region": "us-east-1", "storage_region": "us-east-1"},
})

planes(eu_zone) := json.marshal({
	"eu-west-1": {"zone": eu_zone},
	"us-east-1": {"zone": "us"},
})

router(eu_storage, eu_zone, actions) := {
	"address": "aws_lambda_function.router",
	"type": "aws_lambda_function",
	"change": {"actions": actions, "after": {"environment": [{"variables": {
		"TENANT_REGISTRY": registry(eu_storage),
		"DATA_PLANES": planes(eu_zone),
	}}]}},
}

table(zone, home, replicas) := {
	"address": sprintf("module.data_plane_%s.aws_dynamodb_table.pii", [zone]),
	"type": "aws_dynamodb_table",
	"change": {"actions": ["create"], "after": {
		"name": sprintf("data-residency-pii-%s", [zone]),
		"tags": {"DataClassification": "pii", "ResidencyZone": zone, "HomeRegion": home},
		"replica": replicas,
	}},
}

compliant := {"resource_changes": [
	router("eu-west-1", "eu", ["update"]),
	table("eu", "eu-west-1", []),
	table("us", "us-east-1", []),
]}

test_compliant_plan_passes if {
	count(residency.deny) == 0 with input as compliant
}

test_eu_tenant_routed_to_us_is_denied if {
	msgs := residency.deny with input as {"resource_changes": [router("us-east-1", "eu", ["update"])]}
	some msg in msgs
	contains(msg, "tenant synthetic-eu-01 must stay in eu-west-1")
}

test_region_wired_to_wrong_data_plane_is_denied if {
	msgs := residency.deny with input as {"resource_changes": [router("eu-west-1", "us", ["update"])]}
	some msg in msgs
	contains(msg, "writes for eu-west-1 would go to the us data plane")
}

test_eu_pii_table_in_us_region_is_denied if {
	msgs := residency.deny with input as {"resource_changes": [table("eu", "us-east-1", [])]}
	some msg in msgs
	contains(msg, "must be in eu-west-1")
}

test_pii_table_replica_is_denied if {
	msgs := residency.deny with input as {"resource_changes": [table("eu", "eu-west-1", [{"region_name": "us-east-1"}])]}
	some msg in msgs
	contains(msg, "would be replicated")
}

test_s3_replication_is_denied if {
	msgs := residency.deny with input as {"resource_changes": [{
		"address": "aws_s3_bucket_replication_configuration.logs",
		"type": "aws_s3_bucket_replication_configuration",
		"change": {"actions": ["create"], "after": {}},
	}]}
	count(msgs) == 1
}

test_deleted_resources_are_ignored if {
	count(residency.deny) == 0 with input as {"resource_changes": [router("us-east-1", "eu", ["delete"])]}
}

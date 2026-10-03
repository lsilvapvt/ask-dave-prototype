"""Structural guards on the Terraform code.

Several of these match nothing until the resources they govern exist. They are in
place from iteration 1 so each later iteration is held to the rules automatically:
everything Terraform creates, Terraform must be able to fully destroy.
"""

import re

from repo_files import blocks, terraform_source

TF = terraform_source()


def test_s3_buckets_can_be_destroyed_when_not_empty():
    for name, body in blocks(TF, "resource", "aws_s3_bucket").items():
        assert re.search(r"force_destroy\s*=\s*true", body), (
            f"aws_s3_bucket.{name} needs force_destroy = true, "
            "or destroy fails on a non-empty bucket"
        )


def test_secrets_are_deleted_immediately_on_destroy():
    for name, body in blocks(TF, "resource", "aws_secretsmanager_secret").items():
        assert re.search(r"recovery_window_in_days\s*=\s*0\b", body), (
            f"aws_secretsmanager_secret.{name} needs recovery_window_in_days = 0, otherwise it "
            "lingers 'pending deletion' after destroy and the next deploy collides with its name"
        )


def test_lambdas_log_to_a_terraform_managed_log_group():
    for name, body in blocks(TF, "resource", "aws_lambda_function").items():
        assert "aws_cloudwatch_log_group." in body, (
            f"aws_lambda_function.{name} must reference a Terraform-managed log group "
            "(logging_config or depends_on); a log group Lambda creates itself survives destroy"
        )


def test_log_groups_have_retention():
    for name, body in blocks(TF, "resource", "aws_cloudwatch_log_group").items():
        assert "retention_in_days" in body, (
            f"aws_cloudwatch_log_group.{name} needs retention_in_days"
        )


def test_no_wildcard_iam_resources():
    offenders = re.findall(r'(?i)resources?\s*=\s*\[?\s*"\*"', TF)
    assert not offenders, "IAM statements must name specific resources, not '*'"


def test_secret_like_variables_are_sensitive_and_required():
    for name, body in blocks(TF, "variable").items():
        if re.search(r"key|secret|token|password", name):
            assert re.search(r"sensitive\s*=\s*true", body), f"variable {name} must be sensitive"
            assert not re.search(r"^\s*default\s*=", body, re.M), (
                f"variable {name} must not have a default"
            )


def test_no_aws_region_literals_outside_variable_defaults():
    # The region is an input. Only variables.tf may mention one, as the default.
    source = TF.replace(blocks(TF, "variable").get("aws_region", ""), "")
    offenders = re.findall(r'"[a-z]{2}(?:-gov)?-[a-z]+-\d"', source)
    assert not offenders, f"Hardcoded region literals: {offenders}"

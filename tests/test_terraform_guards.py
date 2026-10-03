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
        if re.search(r"(key|secret|token|password)$", name):
            assert re.search(r"sensitive\s*=\s*true", body), f"variable {name} must be sensitive"
            assert not re.search(r"^\s*default\s*=", body, re.M), (
                f"variable {name} must not have a default"
            )


def test_no_aws_region_literals_outside_variable_defaults():
    # The region is an input. Only variables.tf may mention one, as the default.
    source = TF.replace(blocks(TF, "variable").get("aws_region", ""), "")
    offenders = re.findall(r'"[a-z]{2}(?:-gov)?-[a-z]+-\d"', source)
    assert not offenders, f"Hardcoded region literals: {offenders}"


def test_llm_api_key_is_ephemeral():
    # Ephemeral variables are never written to Terraform state or plan files.
    body = blocks(TF, "variable").get("llm_api_key")
    assert body is not None, "variable llm_api_key must exist"
    assert re.search(r"ephemeral\s*=\s*true", body), "variable llm_api_key must be ephemeral"


def test_secret_values_use_write_only_arguments():
    # secret_string would store the key in state in plain text; secret_string_wo does not.
    for name, body in blocks(TF, "resource", "aws_secretsmanager_secret_version").items():
        assert not re.search(r"^\s*secret_string\s*=", body, re.M), (
            f"aws_secretsmanager_secret_version.{name} must use secret_string_wo, not secret_string"
        )
        assert "secret_string_wo_version" in body, (
            f"aws_secretsmanager_secret_version.{name} needs secret_string_wo_version"
        )


def test_each_lambda_has_its_own_role():
    roles = {
        name: re.search(r"^\s*role\s*=\s*aws_iam_role\.(\w+)\.arn", body, re.M)
        for name, body in blocks(TF, "resource", "aws_lambda_function").items()
    }
    assert all(roles.values()), f"every Lambda must use a Terraform-managed role: {roles}"
    role_names = [m.group(1) for m in roles.values()]
    assert len(role_names) == len(set(role_names)), "Lambdas must not share an IAM role"


def test_history_role_cannot_touch_secrets_or_write_data():
    policy = blocks(TF, "data", "aws_iam_policy_document").get("history")
    if policy is None:
        return
    assert "secretsmanager" not in policy, "the history function must not read secrets"
    assert "s3:PutObject" not in policy, "the history function is read-only"


def test_lambda_roles_cannot_create_log_groups_or_use_broad_managed_policies():
    # Log groups are Terraform-managed; a Lambda that can create its own would
    # recreate one that outlives `terraform destroy`.
    code = "\n".join(line for line in TF.splitlines() if not line.lstrip().startswith(("#", "//")))
    assert "logs:CreateLogGroup" not in code
    assert "AWSLambdaBasicExecutionRole" not in code


def test_lambda_permissions_are_scoped_to_a_source():
    for name, body in blocks(TF, "resource", "aws_lambda_permission").items():
        assert re.search(r"^\s*source_arn\s*=", body, re.M), (
            f"aws_lambda_permission.{name} needs source_arn, or any API could invoke the function"
        )


def test_chat_role_can_only_read_the_key_and_add_history():
    policy = blocks(TF, "data", "aws_iam_policy_document").get("chat")
    if policy is None:
        return
    actions = set(re.findall(r'"((?:s3|secretsmanager|logs|kms):[A-Za-z*]+)"', policy))
    assert actions == {
        "secretsmanager:GetSecretValue",
        "s3:PutObject",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
    }, f"unexpected chat permissions: {sorted(actions)}"
    assert "aws_secretsmanager_secret.llm_api_key.arn" in policy, "scope the secret by its ARN"


def test_llm_key_only_flows_into_the_write_only_secret():
    # var.llm_api_key may feed exactly one attribute: the write-only secret value
    # (plus the variable's own validation condition). Anywhere else (a Lambda
    # environment, an output, a tag) would expose it.
    code = "\n".join(line for line in TF.splitlines() if not line.lstrip().startswith(("#", "//")))
    uses = re.findall(r"^\s*(\w+)\s*=.*\bvar\.llm_api_key\b(?!_)", code, re.M)
    assert sorted(uses) == ["condition", "secret_string_wo"], f"var.llm_api_key used in: {uses}"


def test_public_access_blocks_are_never_relaxed():
    for name, body in blocks(TF, "resource", "aws_s3_bucket_public_access_block").items():
        assert not re.search(r"=\s*false", body), f"public access block {name} relaxes a setting"


def test_every_bucket_gets_the_shared_hardening():
    # storage.tf applies public access blocks, ownership controls and encryption to
    # every bucket listed in local.buckets; a new bucket must be added there too.
    buckets = set(blocks(TF, "resource", "aws_s3_bucket"))
    listed = set(re.findall(r"=\s*aws_s3_bucket\.(\w+)\.id", TF.split("buckets = {", 1)[-1]))
    assert buckets <= listed, f"buckets missing from local.buckets: {sorted(buckets - listed)}"


def test_cloudfront_serves_https_only():
    for name, body in blocks(TF, "resource", "aws_cloudfront_distribution").items():
        policies = re.findall(r'viewer_protocol_policy\s*=\s*"([^"]+)"', body)
        assert policies and set(policies) <= {"redirect-to-https", "https-only"}, (
            f"aws_cloudfront_distribution.{name} must not serve plain HTTP"
        )


def test_frontend_bucket_is_readable_only_by_this_distribution():
    policy = blocks(TF, "data", "aws_iam_policy_document").get("frontend_bucket")
    if policy is None:
        return
    assert '"cloudfront.amazonaws.com"' in policy
    assert "AWS:SourceArn" in policy and "aws_cloudfront_distribution." in policy


def test_index_html_is_uploaded_unmodified_from_the_repo():
    objects = blocks(TF, "resource", "aws_s3_object")
    index = [b for b in objects.values() if re.search(r'key\s*=\s*"index\.html"', b)]
    if not index:
        return
    [body] = index
    assert re.search(r'source\s*=\s*"\$\{path\.module\}/\.\./frontend/index\.html"', body)
    assert not re.search(r"^\s*content\s*=", body, re.M), "index.html must come from the file"


def test_cors_is_not_open_to_every_origin_once_the_frontend_exists():
    if not blocks(TF, "resource", "aws_cloudfront_distribution"):
        return
    assert not re.search(r'allow_origins\s*=\s*\[\s*"\*"', TF), (
        "with the frontend deployed, CORS must allow only the CloudFront origin"
    )


def test_every_lambda_has_an_errors_alarm():
    lambdas = set(blocks(TF, "resource", "aws_lambda_function"))
    if not lambdas:
        return
    alarmed = TF.split("alarmed_lambdas = {", 1)[-1].split("}", 1)[0]
    covered = set(re.findall(r"aws_lambda_function\.(\w+)\.function_name", alarmed))
    assert lambdas <= covered, f"Lambdas without an errors alarm: {sorted(lambdas - covered)}"


def test_alarms_treat_no_traffic_as_healthy():
    # An idle app has no metric data; that must not read as an alarm or as unknown.
    for name, body in blocks(TF, "resource", "aws_cloudwatch_metric_alarm").items():
        assert re.search(r'treat_missing_data\s*=\s*"notBreaching"', body), (
            f"aws_cloudwatch_metric_alarm.{name} needs treat_missing_data = notBreaching"
        )


def test_email_notifications_are_optional():
    # An email subscription needs a manual confirmation click, so it must never be
    # created unless the deployer asked for it.
    for name, body in blocks(TF, "resource", "aws_sns_topic_subscription").items():
        assert re.search(r"count\s*=\s*local\.notify", body), (
            f"aws_sns_topic_subscription.{name} must only exist when alarm_email is set"
        )

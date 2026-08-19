output "state_machine_arn" {
  value = aws_sfn_state_machine.content_pipeline.arn
}

output "state_machine_name" {
  value = aws_sfn_state_machine.content_pipeline.name
}

output "task_writer_function_arn" {
  value = aws_lambda_function.task_writer.arn
}

output "task_writer_role_arn" {
  value = aws_iam_role.task_writer.arn
}

output "task_reviewer_function_arn" {
  value = aws_lambda_function.task_reviewer.arn
}

output "finalize_function_arn" {
  value = aws_lambda_function.finalize.arn
}

output "artifacts_bucket_name" {
  value = aws_s3_bucket.artifacts.bucket
}

output "artifacts_bucket_arn" {
  value = aws_s3_bucket.artifacts.arn
}

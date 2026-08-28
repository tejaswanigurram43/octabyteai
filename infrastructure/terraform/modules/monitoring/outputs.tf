output "sns_topic_arn"   { value = aws_sns_topic.alarms.arn }
output "log_group_app"   { value = aws_cloudwatch_log_group.app.name }
output "log_group_system" { value = aws_cloudwatch_log_group.system.name }
output "log_group_access" { value = aws_cloudwatch_log_group.access.name }
output "dashboard_infrastructure" { value = aws_cloudwatch_dashboard.infrastructure.dashboard_arn }
output "dashboard_application"    { value = aws_cloudwatch_dashboard.application.dashboard_arn }

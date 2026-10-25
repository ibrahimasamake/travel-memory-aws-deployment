
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "public_subnet_2_id" {
  value = aws_subnet.public_2.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "private_subnet_2_id" {
  value = aws_subnet.private_2.id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "ID of the public route table"
  value       = aws_route_table.public.id
}

output "alb_dns_name" {
  description = "Public ALB DNS name - target of the Cloudflare CNAME record"
  value       = aws_lb.app_alb.dns_name
}

output "backend_alb_dns_name" {
  description = "Internal ALB DNS name - used in the Nginx proxy_pass for /trip"
  value       = aws_lb.app_backend_alb.dns_name
}

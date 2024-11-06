
# # ECS cluster
# resource "aws_ecs_cluster" "cluster" {
#   name = "example-ecs-cluster"
#   setting {
#     name  = "containerInsights"
#     value = "enabled"
#   }
# }

# # Task definition
# resource "aws_ecs_task_definition" "nginx_task" {
#   family                   = "service"
#   network_mode             = "awsvpc"
#   requires_compatibilities = ["FARGATE", "EC2"]
#   cpu                      = 512
#   memory                   = 2048

#   container_definitions = jsonencode([
#     {
#       name : "nginx",
#       image : "nginx:1.23.1",
#       cpu : 512,
#       memory : 2048,
#       essential : true,
#       portMappings : [
#         {
#           containerPort : 80,
#           hostPort : 80,
#         },
#       ],
#     },
#   ])
# }
# # Service definition
# resource "aws_ecs_service" "service" {
#   name             = "service"
#   cluster          = aws_ecs_cluster.cluster.id
#   task_definition  = aws_ecs_task_definition.nginx_task.arn
#   desired_count    = 3
#   launch_type      = "FARGATE"
#   platform_version = "LATEST"

#   network_configuration {
#     assign_public_ip = true
#     security_groups  = [aws_security_group.ecs_sg.id]
#     subnets          = [aws_subnet.subnets["jump-vpc.subnet-1"].id]
#   }

#   lifecycle {
#     ignore_changes = [task_definition]
#   }
# }

# # Security group for ECS
# resource "aws_security_group" "ecs_sg" {
#   name        = "ecs_security_group"
#   description = "Allow inbound traffic to ECS containers"
#   vpc_id      = aws_vpc.vpcs["jump-vpc"].id

#   ingress {
#     from_port   = 80
#     to_port     = 80
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
# }

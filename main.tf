locals {
  user_data = templatefile("${path.module}/templates/user-data.txt", {
    wg_server_private_key = data.aws_ssm_parameter.wg_server_private_key.value
    wg_server_net         = var.wg_server_net
    wg_server_port        = var.wg_server_port
    peers                 = join("\n", local.wg_client_data_json)
    use_eip               = var.use_eip ? "enabled" : "disabled"
    eip_id                = var.eip_id
    wg_server_interface   = var.wg_server_interface
  })

  wg_client_data_json = [
    for client in var.wg_client_public_keys : templatefile("${path.module}/templates/client-data.tpl", {
      client_pub_key       = element(values(client), 0)
      client_ip            = element(keys(client), 0)
      persistent_keepalive = var.wg_persistent_keepalive
    })
  ]
}

# We're using ubuntu images - this lets us grab the latest image for our region from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-16.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# turn the sg into a sorted list of string
locals {
  sg_wireguard_external = sort([aws_security_group.sg_wireguard_external.id])
}

# clean up and concat the above wireguard default sg with the additional_security_group_ids
locals {
  security_groups_ids = compact(concat(var.additional_security_group_ids, local.sg_wireguard_external))
}

resource "aws_launch_configuration" "wireguard_launch_config" {
  name_prefix                 = "wireguard-${var.env}-"
  image_id                    = var.ami_id == null ? data.aws_ami.ubuntu.id : var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.ssh_key_id
  iam_instance_profile        = (var.use_eip ? aws_iam_instance_profile.wireguard_profile[0].name : null)
  user_data                   = local.user_data
  security_groups             = local.security_groups_ids
  associate_public_ip_address = var.use_eip

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "wireguard_asg" {
  name                 = aws_launch_configuration.wireguard_launch_config.name
  launch_configuration = aws_launch_configuration.wireguard_launch_config.name
  min_size             = var.asg_min_size
  desired_capacity     = var.asg_desired_capacity
  max_size             = var.asg_max_size
  vpc_zone_identifier  = var.subnet_ids
  health_check_type    = "EC2"
  termination_policies = ["OldestLaunchConfiguration", "OldestInstance"]
  target_group_arns    = var.target_group_arns

  lifecycle {
    create_before_destroy = true
  }

  tags = [
    {
      key                 = "Name"
      value               = aws_launch_configuration.wireguard_launch_config.name
      propagate_at_launch = true
    },
    {
      key                 = "Project"
      value               = "wireguard"
      propagate_at_launch = true
    },
    {
      key                 = "env"
      value               = var.env
      propagate_at_launch = true
    },
    {
      key                 = "tf-managed"
      value               = "True"
      propagate_at_launch = true
    },
  ]
}

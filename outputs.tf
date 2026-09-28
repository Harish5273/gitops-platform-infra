output "public_ip" {
  value = aws_eip.k3s.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/gitops-platform ubuntu@${aws_eip.k3s.public_ip}"
}

output "ami_used" {
  value = data.aws_ami.ubuntu.id
}

output "instance_id" {
  value = aws_instance.k3s.id
}

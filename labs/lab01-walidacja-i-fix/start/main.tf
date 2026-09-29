# Moduł logów aplikacji quotes-api.
# Napisany przez asystenta AI, przeszedł `terraform validate` i trafił do PR.
# Twoje zadanie: znaleźć, co jest z nim nie tak.

locals {
  prefix = "szkolenie-lab01-${var.uczestnik}"
}

data "aws_vpc" "kolektor" {
  id = var.vpc_id
}

resource "aws_s3_bucket" "logi" {
  bucket = "${local.prefix}-logs"

  tags = {
    Projekt   = "ai-devops-cicd"
    Uczestnik = var.uczestnik
    Blok      = "lab01"
    Usuwac    = "tak"
  }
}

resource "aws_s3_bucket_versioning" "logi" {
  bucket = aws_s3_bucket.logi.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Błąd 1: brakowało jawnego szyfrowania. Bucket miał wersjonowanie i blokadę
# dostępu publicznego, ale nie SSE — moduł referencyjny (infra/modules/app-storage)
# i CLAUDE.md wymagają tego wprost dla każdego bucketu S3.
resource "aws_s3_bucket_server_side_encryption_configuration" "logi" {
  bucket = aws_s3_bucket.logi.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logi" {
  bucket = aws_s3_bucket.logi.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "kolektor" {
  name = "${local.prefix}-collector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Projekt   = "ai-devops-cicd"
    Uczestnik = var.uczestnik
    Blok      = "lab01"
    Usuwac    = "tak"
  }
}

resource "aws_iam_role_policy" "kolektor" {
  name = "${local.prefix}-write-logs"
  role = aws_iam_role.kolektor.id

  # Błąd 3: Resource był zahardkodowany na bucket uczestnika "anna-k".
  # Działało to tylko u autora — u każdego innego uczestnika (np. piotr-w)
  # rola nie miałaby dostępu do WŁASNEGO bucketu, bo ARN by się nie zgadzał.
  # Odwołanie do zasobu utworzonego wyżej w tym samym pliku jest portowalne.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject"]
      Resource = "${aws_s3_bucket.logi.arn}/*"
    }]
  })
}

resource "aws_security_group" "kolektor" {
  name        = "${local.prefix}-collector"
  description = "Kolektor logow"
  vpc_id      = var.vpc_id

  # Błąd 2: opis mówi "sieć wewnętrzna", ale cidr_blocks wpuszczał cały internet.
  # Ani Trivy (AVD-AWS-0107 reaguje tylko na porty 22/3389), ani Checkov tego nie
  # zgłaszają dla portu 514 — to błąd widoczny tylko przy czytaniu, nie w skanerze.
  # Zawężone do CIDR-u VPC, w której działa kolektor, więc opis i reguła są spójne.
  ingress {
    description = "Syslog z sieci wewnetrznej"
    from_port   = 514
    to_port     = 514
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.kolektor.cidr_block]
  }

  egress {
    description = "HTTPS do S3"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Projekt   = "ai-devops-cicd"
    Uczestnik = var.uczestnik
    Blok      = "lab01"
    Usuwac    = "tak"
  }
}

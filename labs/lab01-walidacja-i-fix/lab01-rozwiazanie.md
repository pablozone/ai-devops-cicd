# Lab01 — rozwiązanie

> Notatka własna z przebiegu ćwiczenia. Zgodnie z README laba, oficjalne rozwiązanie
> omawia prowadzący — ten plik to zapis tego, co i jak naprawiłem, do własnego użytku.

## Co wykonałem

1. Doinstalowałem brakujące narzędzie **Trivy** (0.74.0) — opcjonalne w `check-prereqs.sh`,
   ale wymagane przez `trivy config .` z instrukcji tego laba.
2. Przeszedłem cykl walidacji z README **przed** poprawką, żeby zobaczyć, co faktycznie
   łapią skanery:
   ```bash
   cd labs/lab01-walidacja-i-fix/start
   terraform init -backend=false
   terraform validate
   tflint
   checkov -d . --compact
   trivy config .
   ```
3. Znalazłem i naprawiłem trzy celowo wprowadzone błędy w `start/main.tf`.
4. Uruchomiłem cały zestaw narzędzi ponownie **po** poprawce i porównałem wyniki.

## Trzy błędy i naprawa

### Błąd 1 — brak szyfrowania bucketu logów

Bucket miał wersjonowanie i blokadę dostępu publicznego, ale brakowało jawnego zasobu
`aws_s3_bucket_server_side_encryption_configuration` — sprzecznie z konwencją repo
(`.claude/CLAUDE.md`: „Bucket S3: szyfrowanie włączone...") i modułem referencyjnym
`infra/modules/app-storage`.

**Naprawa:** dodany zasób SSE z `AES256`, tak jak w module referencyjnym.

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "logi" {
  bucket = aws_s3_bucket.logi.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

**Uwaga do metody:** obecny Checkov (3.3.20) i tak zwraca `PASSED` dla `CKV_AWS_19`
nawet bez tego zasobu, bo AWS od 2023 włącza domyślne SSE-S3 automatycznie na każdym
buckecie. To dobry przykład na to, że skanery ewoluują i przestają łapać rzeczy, które
kiedyś łapały — mimo to warto mieć to jawnie w kodzie, zgodnie z konwencją repo, zamiast
polegać na cichym domyślnym zachowaniu AWS.

### Błąd 2 — reguła ingress niezgodna z własnym opisem (nie widzi go skaner)

Reguła miała opis „Syslog z sieci wewnętrznej", ale `cidr_blocks = ["0.0.0.0/0"]` —
wpuszczała cały internet na port 514. Potwierdzone uruchomieniem Trivy i Checkova przed
i po poprawce: **żaden z nich tego nie zgłasza** (zgodnie z sekcją „Pułapki" w README
laba — reguła `AVD-AWS-0107` w Trivy reaguje tylko na porty 22/3389, nie na 514).

**Naprawa:** dodany `data "aws_vpc"` po `var.vpc_id`, `cidr_blocks` zawężony do CIDR-u
tej konkretnej VPC — opis i reguła są teraz spójne, bez hardkodowania adresu.

```hcl
data "aws_vpc" "kolektor" {
  id = var.vpc_id
}
```

```hcl
ingress {
  description = "Syslog z sieci wewnetrznej"
  from_port   = 514
  to_port     = 514
  protocol    = "tcp"
  cidr_blocks = [data.aws_vpc.kolektor.cidr_block]
}
```

### Błąd 3 — IAM policy zahardkodowana na jednego uczestnika (niewidoczny dla skanera)

`Resource` w polityce roli kolektora był ustawiony na
`arn:aws:s3:::szkolenie-lab01-anna-k-logs/*` — na sztywno na uczestnika „anna-k", mimo
że bucket wyżej w tym samym pliku tworzony jest dynamicznie z `${local.prefix}`.
Efekt: u każdego innego uczestnika (np. `piotr-w`) rola nie miałaby dostępu do
**własnego** bucketu. Kod jest poprawny i bezpieczny politykowo, po prostu nie działa
u nikogo poza autorem — żaden skaner tego nie łapie, bo to nie jest luka bezpieczeństwa,
tylko błąd logiczny/portowości.

**Naprawa:** hardkodowany ARN zamieniony na odwołanie do zasobu z tego samego pliku.

```hcl
Resource = "${aws_s3_bucket.logi.arn}/*"
```

## Weryfikacja końcowa

- `terraform fmt -check` — OK (bez zmian formatowania)
- `terraform validate` — `Success!`
- **Checkov** — te same 6 zgłoszeń co przed poprawką (replikacja, event notifications,
  SG niepodłączony do zasobu, access logging, brak KMS) — identyczne jak kategoria
  „świadomych decyzji" z tabeli w `infra/modules/app-storage/README.md`. To nie są
  nasze trzy błędy i zostają bez zmian, bez `#checkov:skip`.
- **Trivy** — te same 3 zgłoszenia co przed poprawką (`AWS-0089` logging, `AWS-0104`
  egress 443, `AWS-0132` brak CMK) — dokładnie te, które README każe **uzasadnić, nie
  naprawiać** (kolektor musi wysyłać po HTTPS do S3; SSE-S3 wystarcza zamiast CMK dla
  logów tego typu).
- Brak regresji: liczba zgłoszeń skanerów nie wzrosła po zmianach.
- Nie użyto `#checkov:skip` ani `#tfsec:ignore` — naprawiona przyczyna, nie wyciszone
  zgłoszenie.

## Poza zakresem naprawy

TFLint zgłasza `variable "region" is declared but not used` w `variables.tf`.
Nie jest to jeden z trzech zadanych błędów (nie pasuje do żadnej podpowiedzi w README
laba), więc pozostawione bez zmian — zgodnie z zasadą „nie naprawiaj czegoś, o co nie
proszono".

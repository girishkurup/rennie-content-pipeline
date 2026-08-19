variable "name_prefix" {
  description = "Prefix applied to the user pool, domain, and client names."
  type        = string
}

variable "callback_urls" {
  description = "OAuth callback URLs allowed for the SPA app client (Hosted UI redirects here after login)."
  type        = list(string)
  default     = ["http://localhost:5173/callback"]
}

variable "logout_urls" {
  description = "OAuth logout URLs allowed for the SPA app client."
  type        = list(string)
  default     = ["http://localhost:5173/"]
}

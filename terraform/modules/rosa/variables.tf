variable "rosa_clusters" {
  type = map(any)
}

variable "region" {
  type = string
}

variable "subnets" {
  type = map(object({
    id                = string
    availability_zone = string
  }))
}



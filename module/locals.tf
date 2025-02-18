locals {
    runtime = "python3.11"
    wildcard_patterns = flatten([
    for position in range(12) : [
      for digit in range(10) : {
        userid_wildcard   = join("", [for i in range(12) : i == position ? digit : "-"])
        account_wildcard  = join("", [for i in range(12) : i == position ? digit : "?"])
      }
    ]
  ])
}

# Maintaining Yorkie

## Releasing a New Version

### Updating and Deploying Yorkie

1. Update the sdk version 
  - Update the yorkieVersion value in the Sources/Version.swift file to the next release version. That value must match the tag name since swift package managers use the tag name as the version. 
  https://github.com/yorkie-team/yorkie-ios-sdk/blob/a32b919d3b99312a6251122e630f895d1eb94f83/Sources/Version.swift#L19  
2. Create [a new release](https://github.com/yorkie-team/yorkie-ios-sdk/releases/new) with changelog by clicking `Generate changelog` button.

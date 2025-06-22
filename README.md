# Yorkie iOS SDK

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fyorkie-team%2Fyorkie-ios-sdk%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/yorkie-team/yorkie-ios-sdk)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fyorkie-team%2Fyorkie-ios-sdk%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/yorkie-team/yorkie-ios-sdk)
[![Swift Package Manager](https://img.shields.io/badge/Swift_Package_Manager-compatible-orange?style=flat-square)](https://img.shields.io/badge/Swift_Package_Manager-compatible-orange?style=flat-square)
[![codecov](https://codecov.io/gh/yorkie-team/yorkie-ios-sdk/branch/main/graph/badge.svg?token=USX8DU19YO)](https://codecov.io/gh/yorkie-team/yorkie-ios-sdk)

Yorkie iOS SDK provides a suite of tools for building real-time collaborative applications.

## How to use

See [Getting Started with iOS SDK](https://yorkie.dev/docs/getting-started/with-ios-sdk) for the instructions.

Example projects can be found in the [examples](https://github.com/yorkie-team/yorkie-ios-sdk/tree/main/Examples) folder.

Read the [full documentation](https://yorkie.dev/docs) for all details.

## Testing yorkie-ios-sdk with Envoy, Yorkie and MongoDB.

Start MongoDB, Yorkie and Envoy proxy in a terminal session.

```bash
$ docker-compose -f docker/docker-compose.yml up --build -d
```

Start the test in another terminal session.

```bash
$ swift test
```

To get the latest server locally, run the command below then restart containers again:

```bash
$ docker pull yorkieteam/yorkie:latest
$ docker-compose -f docker/docker-compose.yml up --build -d
```

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md) for details on submitting patches and the contribution workflow.

## Contributors ✨

Thanks goes to these incredible people:

<a href="https://github.com/yorkie-team/yorkie-ios-sdk/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=yorkie-team/yorkie-ios-sdk" />
</a>

test

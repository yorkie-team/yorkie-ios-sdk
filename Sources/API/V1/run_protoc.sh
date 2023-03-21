#/bin/bash

protoc --swift_out=. yorkie/v1/*.proto 
protoc yorkie/v1/yorkie.proto --grpc-swift_opt=Client=true,Server=false,FileNaming=DropPath --grpc-swift_out=yorkie/v1/

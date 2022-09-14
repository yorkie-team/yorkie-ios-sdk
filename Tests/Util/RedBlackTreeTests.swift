//
//  RedBlackTreeTests.swift
//  Yorkie
//
//  Created by Hyeongsik Won on 2022/09/14.
//  
// 

import XCTest
import Combine
@testable import SmartEditorCore

class RedBlackTreeTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()
    
    override func setUp() {
        super.setUp()
    }
    
    override func tearDown() {
        super.tearDown()
    }
        
    func test_<#동작 시나리오#>() throws {
        <#var target: #>
        <#var result: #>
        
        given {
            let configKey = prepareConfiguration()

            <#// 테스트 환경 준비#>
        }
        
        when {
            <#// 테스트 동작 실행#>
        }
        
        then {
            <#// 기대 결과 검증#>
        }
    }
}


//
//  IndexTreeTests.swift
//  YorkieTests
//
//  Created by Jung gyun Ahn on 2023/07/03.
//

import XCTest

final class IndexTreeTests: XCTestCase {
    /*
     func test_can_find_position_from_the_given_offset() throws {
         //    0   1 2 3 4 5 6    7   8 9  10 11 12 13    14
         // <r> <p> h e l l o </p> <p> w  o  r  l  d  </p>  </r>
         const tree = buildIndexTree({
         type: 'r',
         children: [
             { type: 'p', children: [{ type: 'text', value: 'hello' }] },
             { type: 'p', children: [{ type: 'text', value: 'world' }] },
         ],
         });

         let pos = tree.findTreePos(0);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['r', 0]);
         pos = tree.findTreePos(1);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['text.hello', 0]);
         pos = tree.findTreePos(6);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['text.hello', 5]);
         pos = tree.findTreePos(6, false);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['p', 1]);
         pos = tree.findTreePos(7);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['r', 1]);
         pos = tree.findTreePos(8);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['text.world', 0]);
         pos = tree.findTreePos(13);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['text.world', 5]);
         pos = tree.findTreePos(14);
         assert.deepEqual([toDiagnostic(pos.node), pos.offset], ['r', 2]);
     }
      */
}

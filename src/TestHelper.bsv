/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package TestHelper;
/*
    Description
        Used in test modules to define an interface to start a test and check if the test has completed.
*/
    interface TestHandler;
        method Action go();
        method Bool done();
    endinterface
endpackage

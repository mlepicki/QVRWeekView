//
//  EventFrameCalculator.swift
//  QVRWeekView
//
//  Created by Reinert Lemmens on 7/28/17.
//

import Foundation

class FrameCalculator {

    let date: DayDate
    weak var delegate: FrameCalculatorDelegate?

    private var csp: ConstraintSolver?
    private var cancelFlag: Bool = false

    var isCalculating: Bool {
        return !cancelFlag
    }
    var width: CGFloat {
        return LayoutVariables.dayViewCellWidth
    }
    var height: CGFloat {
        return LayoutVariables.dayViewCellHeight
    }

    init(date: DayDate) {
        self.date = date
    }

    // Calculate and return the solution
    func calculate(withData eventsData: [Int: EventData]) {

        DispatchQueue.global(qos: .userInitiated).async {
            let n = eventsData.count
            let endPoints = self.calculateEndPoints(for: eventsData)
            var constraints: [[Bool]] = Array(repeating: Array(repeating: false, count: n), count: n)
            var domains: [Set<WidthPosValue>] = []

            var eventFrames: [EventFrame] = []
            var sweepState = Set<EventFrame>()
            var possibleFrameCollisions: [EventFrame: [EventFrame]] = [:]

            var frameIndices: [EventFrame: Int] = [:]
            var areCollisions = false
            var index = 0

            // Sweep through all frames from top to bottom
            for point in endPoints {
                if point.isStart {
                    // If collisions, resize and reposition the frames.
                    if !sweepState.isEmpty {
                        if !areCollisions { areCollisions = true }
                        // Calculate new width
                        let newWidth = self.width/CGFloat(sweepState.count+1)
                        for frame in sweepState {
                            frame.width = newWidth < frame.width ? newWidth : frame.width
                            if possibleFrameCollisions[point.frame] != nil { possibleFrameCollisions[point.frame]!.append(frame) }
                            else { possibleFrameCollisions[point.frame] = [frame] }
                            if possibleFrameCollisions[frame] != nil { possibleFrameCollisions[frame]!.append(point.frame) }
                            else { possibleFrameCollisions[frame] = [point.frame] }
                        }
                        point.frame.width = newWidth
                    }
                    sweepState.insert(point.frame)
                }
                else {
                    // Remove from sweepingline and add to eventFrames
                    let frame = point.frame
                    sweepState.remove(frame)
                    eventFrames.append(frame)
                    domains.append(self.domain(forFrame: frame, .subOptimal))
                    frameIndices[frame] = index
                    index += 1
                }
            }

            var frames: [Int: CGRect]?
            if areCollisions {
                // Register possible collisions as constraints
                for (frame1, frameList) in possibleFrameCollisions {
                    let index1 = frameIndices[frame1]!
                    for frame2 in frameList {
                        let index2 = frameIndices[frame2]!
                        constraints[index1][index2] = true
                    }
                }

                // Create constraint solver and run backtracking algorithm
                self.csp = ConstraintSolver(domains: domains, constraints: constraints, variables: eventFrames)
                if !self.cancelFlag {
                    frames = self.csp?.solveWithBacktracking()
                }
                DispatchQueue.main.sync {
                    self.delegate?.passSolution(fromCalculator: self, solution: frames)
                }
            }
            else {
                // If no collisions found, return the frames as they are
                if !self.cancelFlag {
                    frames = [:]
                    for frame in eventFrames {
                        frames![frame.id] = frame.cgRect
                    }
                }
                DispatchQueue.main.sync {
                    self.delegate?.passSolution(fromCalculator: self, solution: frames)
                }
            }
        }
    }

    func cancelCalculation() {
        cancelFlag = true
        csp?.cancel()
    }

    // Generate end points used during sweep phase
    private func calculateEndPoints(`for` eventsData: [Int: EventData]) -> [EndPoint] {
        var endPoints: [EndPoint] = []
        for (id, data) in eventsData {
            let frame = getEventFrame(withData: data)
            endPoints.append(EndPoint(y: frame.y, id: id, frame: frame, isStart: true))
            endPoints.append(EndPoint(y: frame.y2, id: id, frame: frame, isStart: false))
        }

        endPoints.sort(by: {(e1, e2) -> Bool in
            if e1.y.isEqual(to: e2.y, decimalPlaces: 12) {
                if e1.isEnd && e2.isStart {
                    return true
                }
                else if e1.isStart && e2.isEnd {
                    return false
                }
            }
            return e1.y < e2.y
        })
        return endPoints
    }

    // Generate domain of possible width and position values based on width of frame
    private func domain(forFrame frame: EventFrame, _ choice: DomainChoice = .subOptimal) -> Set<WidthPosValue> {
        var domain = Set<WidthPosValue>()
        let count = Int(self.width/frame.width)
        var i = 0
        if choice == .optimal { i = 1 }
        else if choice == .subOptimal { i = count == 1 ? 1 : (count <= 4 ? 2 : (count <= 6 ? count-2 : (count <= 7 ? count-1 : count))) }
        else { i = count }

        while i <= count {
            let width = self.width/CGFloat(i)
            for a in 0...(i-1) {
                domain.insert(WidthPosValue(x: CGFloat(a)*width, width: width))
            }
            i += 1
        }
        return domain
    }

    // Domain choice enum
    private enum DomainChoice {
        case optimal
        case subOptimal
        case singular
    }

    // Return event frame based on event data
    private func getEventFrame(withData data: EventData) -> EventFrame {
        let time = data.startDate.getTimeInHours()
        let duration = data.endDate.getTimeInHours() - time
        let hourHeight = self.height/DateSupport.hoursInDay
        return EventFrame(x: 0,
                          y: hourHeight*CGFloat(time),
                          width: self.width,
                          height: hourHeight*CGFloat(duration),
                          id: data.id)
    }

    // Struct used for endpoints
    private struct EndPoint: CustomStringConvertible {
        var y: CGFloat
        var id: Int
        var frame: EventFrame
        var isStart: Bool
        var isEnd: Bool {
            return !isStart
        }
        var description: String {
            return "{y: \(y), id: \(id), isStart: \(isStart)}\n"
        }
    }
}

// MARK: - FrameCalculator Delegate -

protocol FrameCalculatorDelegate: class {

    func passSolution(fromCalculator calculator: FrameCalculator, solution: [Int: CGRect]?)

}

// MARK: - Constraint Optimization -

fileprivate class ConstraintSolver {

    let domains: [Set<WidthPosValue>]
    let variables: [EventFrame]
    let constraints: [[Bool]]
    let n: Int
    let startTime: TimeInterval
    private var cancelled: Bool = false

    init (domains: [Set<WidthPosValue>], constraints: [[Bool]], variables: [EventFrame]) {
        self.variables = variables
        self.constraints = constraints
        self.domains = domains
        self.n = variables.count
        self.startTime = Date.timeIntervalSinceReferenceDate
    }

    func solveWithBacktracking() -> [Int: CGRect]? {
        return backtrack()
    }

    private func backtrack() -> [Int: CGRect]? {

        if !backtrack(depth: 0) && !cancelled {
            print("BACKTRACK FAILED ON VARIABLES: \(variables)")
        }

        if cancelled {
            return nil
        }
        else {
            var solution: [Int: CGRect] = [:]
            for vari in variables {
                solution[vari.id] = vari.cgRect
            }
            return solution
        }
    }

    private func backtrack(depth: Int) -> Bool {

        let domain = domains[depth].sorted(by: { (v1, v2) -> Bool in
            if v1.width.isEqual(to: v2.width, decimalPlaces: 12) {
                return v1.x < v2.x
            } else { return v1.width > v2.width }
        })

        for value in domain {
            if Date.timeIntervalSinceReferenceDate-startTime > 15.0 || cancelled {
                return true
            }
            let activeFrame = variables[depth]
            activeFrame.applyValue(value)
            var noFails = true
            var a = 0
            while a < depth {
                if !constraintIsSatsified(activeDepth: depth, checkDepth: a) {
                    noFails = false
                    break
                }
                a += 1
            }
            if noFails {
                if depth == (n-1) {
                    return true
                }
                else {
                    let nextDepth = depth + 1
                    if backtrack(depth: nextDepth) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func constraintIsSatsified(activeDepth d1: Int, checkDepth d2: Int) -> Bool {

        if constraints[d1][d2] {
            let f1 = variables[d1]
            let f2 = variables[d2]

            // Left corner of f1 is inside f2
            let lci1 = ((f2.x < f1.x || f1.x.isEqual(to: f2.x, decimalPlaces: 12)) && (f1.x < f2.x2))
            // Right corner of f1 is inside f2
            let rci1 = ((f2.x < f1.x2) && (f1.x2 < f2.x2 || f1.x2.isEqual(to: f2.x2, decimalPlaces: 12)))
            // Left corner of f2 is inside f1
            let lci2 = ((f1.x < f2.x || f2.x.isEqual(to: f1.x, decimalPlaces: 12)) && (f2.x < f1.x2))
            // Right corner of f2 is inside f1
            let rci2 = ((f1.x < f2.x2) && (f2.x2 < f1.x2 || f2.x2.isEqual(to: f1.x2, decimalPlaces: 12)))
            // Left corner f1 is not inside f2 and right corner f1 is not inside f2
            return (!lci1 && !rci1) && (!lci2 && !rci2)
        }
        else {
            return true
        }
    }

    fileprivate func cancel() {
        self.cancelled = true
    }
}

fileprivate class EventFrame: CustomStringConvertible, Hashable {

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, id: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.id = id
    }

    let id: Int
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var y2: CGFloat {
        return self.y + self.height
    }

    var x2: CGFloat {
        return self.x + self.width
    }

    var description: String {
        return "{x: \(x), y: \(y), width: \(width), height: \(height), id: \(id)}\n"
    }

    var cgRect: CGRect {
        return CGRect(x: self.x, y: self.y, width: self.width, height: self.height)
    }

    var hashValue: Int {
        return id
    }

    static func == (lhs: EventFrame, rhs: EventFrame) -> Bool {
        return lhs.id == rhs.id
    }

    func intersects(withFrameFrom eventFrames: [EventFrame]) -> Bool {
        for frame in eventFrames {
            if self.cgRect.intersects(frame.cgRect) {
                return true
            }
        }
        return false
    }

    func swapPositions(withFrame eventFrame: EventFrame) {
        let oldX = self.x
        self.x = eventFrame.x
        eventFrame.x = oldX
    }

    func getCGReact(withValue value: WidthPosValue) -> CGRect {
        return CGRect(x: value.x, y: self.y, width: value.width, height: self.height)
    }

    func applyValue(_ value: WidthPosValue) {
        self.width = value.width
        self.x = value.x
    }
}

fileprivate struct WidthPosValue: Hashable, CustomStringConvertible {
    var x: CGFloat
    var width: CGFloat

    var hashValue: Int {
        return "[\(x),\(width)]".hashValue
    }

    var description: String {
        return "\n{x: \(x), width: \(width)}"
    }

    static func == (lhs: WidthPosValue, rhs: WidthPosValue) -> Bool {
        return lhs.x.isEqual(to: rhs.x, decimalPlaces: 12) && lhs.width.isEqual(to: rhs.width, decimalPlaces: 12)
    }
}

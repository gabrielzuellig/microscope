
/*
# This script load and cleans the Michigan Survey of Consumers dataset, 
# merges it with oil price changes and runs a few descriptive regressions 
# with various fixed effects specifications
*/


*** Program setup
capture log close
clear all
macro drop _all
set more off
set segmentsize 2g
program drop _all
global path = "/Users/gabrielzullig/Dropbox/Teaching/Basel2026/microscope/"
global taskname = "R06_MSC"
cap mkdir $path/$taskname  // cap = only execute if it doesn't lead to error, otherwise ignore

** Load raw data 
import delim using $path/data/msc_in.csv, varn(1) clear
describe

** Timeset the data 
gen mon = yyyymm - yyyy*100
gen date = ym(yyyy, mon)
format date %tm
gen dateqtr = qofd(dofm(date))
gen yyyy_pr = substr(datepr, 1, 4)
destring yyyy_pr, replace
gen mon_pr = substr(datepr, 5, 6)
destring mon_pr, replace
gen prevdate = ym(yyyy_pr, mon_pr)
format prevdate %tm
gen interval = date - prevdate   // time intervals between 2 interviews, if any
tab interval, m   // almost exclusively 6 months
// mark re-interviews 
destring idprev, replace
gen hasprevious = idprev != .
tab hasprevious  // around 1/3 are re-interviews 


** Show number of interviews by month 
preserve // everything between 'preserve' and 'restore' should be run combined so original data is not erased from workspace

collapse (count) nint=caseid (sum) reint=hasprevious, by(date)
graph twoway (line nint date) ///
	(line reint date, lp(dash)), ///
	legend(pos(6) order(1 "Interviews" 2 "of which re-interviews"))

restore 


** Prepare variables
* inflexp: inflation expectations
sum px1, det
gen inflexp = px1 if abs(px1) < 95 // abs > 95 are value like don't know or invalid answers
sum inflexp, det
hist inflexp
destring vehown, replace 
gen nocar = 0 if vehown == 1  // has a car
replace nocar = 1 if vehown == 5   // has no car
* Keep only the relevant variables
keep caseid id date hasprevious prevdate idprev inflexp nocar


** Average expected inflation over time 
preserve 

collapse (mean) inflexp, by(date)
graph twoway (line inflexp date), xtitle("") ytitle("Average expected inflation")

restore 


** Merge monthly changes of WTI oil price 
preserve 

import delim $path/data/WTISPLC.csv, clear
gen date = ym(real(substr(observation_date, 1, 4)), real(substr(observation_date, 6, 2)))
format date %tm
graph twoway (line wtisplc date)
tsset date 
gen dwti = (wtisplc / L1.wtisplc - 1)*100   // monthly change
graph twoway (line dwti date)
save $path$taskname/wtitemp.dta, replace

restore 

merge m:1 date using $path$taskname/wtitemp.dta, keep(match master) keepusing(dwti) nogen


** REGRESSION OF INFLATION EXPECTATIONS ON OIL PRICE CHANGES
cap ssc install estout
cap ssc install reghdfe
cap ssc install ftoos

** Regression 1: plain vanills
eststo reg1: reg inflexp dwti
// > Average expected inflation over full sample when dwti=0 is 4.6%
// > When WTI is 1%, expected inflation is 0.024pp higher.
// > A 50% oil price increase should push up expected inflation by 1.2pp. 

** Regression 2: Include time fixed effects 
eststo reg2: reghdfe inflexp dwti, absorb(date)   
// > Effect cannot be identified, because time fixed effects absorb all variation in dwti.
//   (time fixed effects and dwti are collinear)

** Regression 3: Exploit cross-section 
eststo reg3: reghdfe inflexp dwti c.dwti#ib0.nocar, absorb(date) 
// > Interaction term with 'nocar' can be estimated, because - holding time fixed --
//   there is still variation in whether or not people own cars
// > People not owning cars only increase expected inflation by half as much
//   (although partial effect is not statistically significant; small share of non-owners)
tab nocar, m

** Including person fixed effect requires reshaping of data to long format
// First, we match 2 interviews (id and idprev) in same row
preserve 

keep date id inflexp 
rename (date id inflexp) (prevdate idprev inflexp_tm6)
save $path$taskname/msctemp.dta, replace

restore

drop if prevdate == . | idprev == .
gen person_id = _n 
order person_id
merge 1:1 prevdate idprev using $path$taskname/msctemp.dta, keep(match master) keepus(inflexp_tm6)
// Second, we reshape from wide to long format
rename (inflexp inflexp_tm6) (inflexp2 inflexp1)
rename (date prevdate) (date2 date1)
keep person_id inflexp* date* nocar
reshape long inflexp date, i(person_id) j(interview_number)  // number of observation exactly doubles
merge m:1 date using $path$taskname/wtitemp.dta, keep(match master) keepusing(dwti) nogen // Merge oil price change for each interview back on
xtset person_id interview_number  // format data as a panel (cross-section: person_id, time dimension: interview:number)

** Regression 4: Include person fixed effect 
eststo reg4: reghdfe inflexp dwti, absorb(person_id)
// > Holding a person fixed, i.e. only exploiting 2 data points "within" a person,
//   increasing oil price by 1% leads to 0.008pp higher expected inflation

** Regression 5: Also add interaction variable again
eststo reg5: reghdfe inflexp dwti c.dwti#ib0.nocar, absorb(person_id)
// > Sample size has decreased (because nocar only defined for half the sample)
// > Interaction term now far from statistically significant, because only exploits 
//   variation of "nocar" within a person, i.e. only people who have a car in one interview
//   and not in the other (very few). Running this regression makes no sense, but it
//   illustrates that we need to think about what variation fixed effects absorb
//   and what variation we are left with



-- =========================================================================
-- xNFTs database setup — PART 07 of 08
-- =========================================================================
--
-- Run these IN ORDER, one at a time, in the Supabase SQL Editor.
-- Wait for each to finish before starting the next.
--
-- Split only at statement boundaries, so no statement is cut in half. Safe to
-- re-run: every statement uses "if not exists", "or replace", or
-- "on conflict do nothing".
--
-- After all 08 parts, run RUN-THIS-SECOND.sql (protocol_config).
-- =========================================================================

-- =========================================================================
-- SECTION 9 of 18 — 20260806090400_seed_xployee_skills.sql
-- =========================================================================

-- xNFTs index — seed: which desks each xployee works.
--
-- 7,900 rows: 3,000 UNCOMMON x 1 + 1,250 RARE x 2 + 600 EPIC x 3 + 150 X-RATED
-- x 4. Emitted from the same `buildXployee` call that produced 20260806090300,
-- so the skill draw and the apy in that file came out of one roll rather than
-- two.
--
-- Columns: (xployee_id, slot, skill_id, proficiency_pct). `slot` is the draw
-- order — `pickDistinct` returns skills in the order it chose them and the
-- xployee sheet lists them that way, so the order is data rather than
-- presentation.

insert into public.xployee_skills (xployee_id, slot, skill_id, proficiency_pct) values
(4179,0,'silicon',61),
(4180,0,'rails',66),
(4181,0,'bills',68),
(4182,0,'brand',99),
(4183,0,'crude',81),
(4184,0,'claims',73),
(4185,0,'bills',68),
(4186,0,'cloud',87),
(4187,0,'ballast',86),
(4188,0,'trial',62),
(4189,0,'shelf',60),
(4190,0,'silicon',67),
(4191,0,'claims',61),
(4192,0,'cloud',86),
(4193,0,'grid',78),
(4194,0,'bills',86),
(4195,0,'shelf',72),
(4196,0,'brand',100),
(4197,0,'shelf',97),
(4198,0,'bills',97),
(4199,0,'brand',67),
(4200,0,'vault',82),
(4201,0,'trial',77),
(4202,0,'ledger',87),
(4203,0,'brand',88),
(4204,0,'brand',94),
(4205,0,'brand',84),
(4206,0,'silicon',90),
(4207,0,'vault',64),
(4208,0,'crude',77),
(4209,0,'degen',72),
(4210,0,'platform',72),
(4211,0,'brand',73),
(4212,0,'shelf',63),
(4213,0,'crude',78),
(4214,0,'claims',88),
(4215,0,'cloud',70),
(4216,0,'bills',96),
(4217,0,'grid',93),
(4218,0,'cloud',68),
(4219,0,'trial',80),
(4220,0,'ledger',83),
(4221,0,'shelf',89),
(4222,0,'cloud',67),
(4223,0,'vault',90),
(4224,0,'platform',66),
(4225,0,'silicon',74),
(4226,0,'shelf',69),
(4227,0,'trial',64),
(4228,0,'shelf',68),
(4229,0,'bills',67),
(4230,0,'ledger',89),
(4231,0,'teller',88),
(4232,0,'bills',93),
(4233,0,'claims',67),
(4234,0,'claims',79),
(4235,0,'grid',80),
(4236,0,'shelf',74),
(4237,0,'brand',92),
(4238,0,'shelf',84),
(4239,0,'platform',100),
(4240,0,'platform',67),
(4241,0,'grid',83),
(4242,0,'brand',79),
(4243,0,'ballast',90),
(4244,0,'shelf',96),
(4245,0,'grid',84),
(4246,0,'rails',92),
(4247,0,'cloud',67),
(4248,0,'ballast',68),
(4249,0,'shelf',63),
(4250,0,'ballast',68),
(4251,0,'grid',74),
(4252,0,'crude',79),
(4253,0,'claims',91),
(4254,0,'crude',95),
(4255,0,'claims',94),
(4256,0,'bills',70),
(4257,0,'brand',63),
(4258,0,'silicon',90),
(4259,0,'brand',76),
(4260,0,'grid',73),
(4261,0,'brand',88),
(4262,0,'vault',96),
(4263,0,'ballast',88),
(4264,0,'crude',95),
(4265,0,'claims',72),
(4266,0,'ballast',60),
(4267,0,'cloud',77),
(4268,0,'ballast',94),
(4269,0,'trial',65),
(4270,0,'trial',80),
(4271,0,'claims',86),
(4272,0,'silicon',88),
(4273,0,'crude',70),
(4274,0,'rails',84),
(4275,0,'brand',93),
(4276,0,'brand',61),
(4277,0,'ballast',82),
(4278,0,'cloud',100),
(4279,0,'bills',94),
(4280,0,'platform',92),
(4281,0,'rails',69),
(4282,0,'cloud',79),
(4283,0,'degen',69),
(4284,0,'trial',78),
(4285,0,'platform',76),
(4286,0,'cloud',67),
(4287,0,'cloud',70),
(4288,0,'shelf',65),
(4289,0,'brand',64),
(4290,0,'ledger',69),
(4291,0,'trial',70),
(4292,0,'ballast',75),
(4293,0,'vault',94),
(4294,0,'teller',81),
(4295,0,'shelf',83),
(4296,0,'vault',100),
(4297,0,'bills',77),
(4298,0,'vault',75),
(4299,0,'grid',86),
(4300,0,'rails',76),
(4301,0,'silicon',75),
(4302,0,'bills',93),
(4303,0,'brand',75),
(4304,0,'grid',78),
(4305,0,'teller',77),
(4306,0,'shelf',89),
(4307,0,'rails',94),
(4308,0,'rails',62),
(4309,0,'ledger',89),
(4310,0,'brand',80),
(4311,0,'vault',88),
(4312,0,'silicon',96),
(4313,0,'shelf',69),
(4314,0,'ballast',81),
(4315,0,'bills',96),
(4316,0,'vault',96),
(4317,0,'vault',100),
(4318,0,'silicon',99),
(4319,0,'shelf',89),
(4320,0,'platform',97),
(4321,0,'crude',90),
(4322,0,'shelf',78),
(4323,0,'rails',92),
(4324,0,'claims',64),
(4325,0,'ledger',85),
(4326,0,'claims',61),
(4327,0,'ballast',91),
(4328,0,'bills',84),
(4329,0,'grid',93),
(4330,0,'ballast',94),
(4331,0,'ballast',62),
(4332,0,'bills',61),
(4333,0,'bills',66),
(4334,0,'degen',85),
(4335,0,'bills',75),
(4336,0,'ballast',84),
(4337,0,'ledger',69),
(4338,0,'bills',93),
(4339,0,'ledger',73),
(4340,0,'ledger',72),
(4341,0,'bills',68),
(4342,0,'teller',94),
(4343,0,'ledger',97),
(4344,0,'shelf',75),
(4345,0,'trial',64),
(4346,0,'brand',75),
(4347,0,'bills',75),
(4348,0,'brand',86),
(4349,0,'bills',60),
(4350,0,'ballast',60),
(4351,0,'vault',70),
(4352,0,'shelf',65),
(4353,0,'ledger',73),
(4354,0,'shelf',64),
(4355,0,'bills',80),
(4356,0,'claims',83),
(4357,0,'ledger',74),
(4358,0,'shelf',86),
(4359,0,'shelf',71),
(4360,0,'vault',87),
(4361,0,'brand',77),
(4362,0,'vault',61),
(4363,0,'ledger',68),
(4364,0,'rails',73),
(4365,0,'vault',60),
(4366,0,'vault',99),
(4367,0,'ledger',65),
(4368,0,'brand',73),
(4369,0,'rails',89),
(4370,0,'grid',78),
(4371,0,'rails',88),
(4372,0,'ballast',92),
(4373,0,'claims',79),
(4374,0,'crude',65),
(4375,0,'vault',89),
(4376,0,'claims',63),
(4377,0,'bills',85),
(4378,0,'brand',89),
(4379,0,'bills',63),
(4380,0,'teller',90),
(4381,0,'shelf',89),
(4382,0,'trial',96),
(4383,0,'cloud',87),
(4384,0,'brand',98),
(4385,0,'ledger',67),
(4386,0,'platform',65),
(4387,0,'claims',85),
(4388,0,'vault',99),
(4389,0,'crude',95),
(4390,0,'silicon',62),
(4391,0,'brand',99),
(4392,0,'vault',96),
(4393,0,'vault',91),
(4394,0,'rails',84),
(4395,0,'brand',97),
(4396,0,'vault',97),
(4397,0,'platform',76),
(4398,0,'ballast',65),
(4399,0,'shelf',63),
(4400,0,'vault',91),
(4401,0,'bills',98),
(4402,0,'cloud',83),
(4403,0,'ledger',63),
(4404,0,'rails',89),
(4405,0,'ballast',89),
(4406,0,'bills',92),
(4407,0,'cloud',92),
(4408,0,'vault',88),
(4409,0,'platform',95),
(4410,0,'ballast',73),
(4411,0,'shelf',63),
(4412,0,'silicon',89),
(4413,0,'grid',82),
(4414,0,'trial',63),
(4415,0,'ballast',92),
(4416,0,'vault',89),
(4417,0,'crude',99),
(4418,0,'ledger',72),
(4419,0,'claims',83),
(4420,0,'trial',71),
(4421,0,'grid',80),
(4422,0,'bills',61),
(4423,0,'shelf',67),
(4424,0,'rails',64),
(4425,0,'trial',62),
(4426,0,'ballast',81),
(4427,0,'shelf',88),
(4428,0,'bills',62),
(4429,0,'crude',80),
(4430,0,'brand',62),
(4431,0,'shelf',63),
(4432,0,'silicon',90),
(4433,0,'claims',91),
(4434,0,'rails',96),
(4435,0,'vault',94),
(4436,0,'cloud',97),
(4437,0,'rails',67),
(4438,0,'platform',65),
(4439,0,'cloud',80),
(4440,0,'ballast',76),
(4441,0,'bills',88),
(4442,0,'rails',90),
(4443,0,'shelf',84),
(4444,0,'claims',94),
(4445,0,'grid',80),
(4446,0,'bills',68),
(4447,0,'brand',96),
(4448,0,'vault',79),
(4449,0,'vault',74),
(4450,0,'ballast',96),
(4451,0,'teller',67),
(4452,0,'cloud',65),
(4453,0,'claims',72),
(4454,0,'claims',68),
(4455,0,'bills',82),
(4456,0,'rails',72),
(4457,0,'vault',74),
(4458,0,'shelf',64),
(4459,0,'crude',67),
(4460,0,'crude',71),
(4461,0,'rails',87),
(4462,0,'ballast',70),
(4463,0,'rails',82),
(4464,0,'bills',79),
(4465,0,'platform',87),
(4466,0,'platform',94),
(4467,0,'ballast',60),
(4468,0,'bills',82),
(4469,0,'claims',80),
(4470,0,'degen',98),
(4471,0,'platform',75),
(4472,0,'claims',77),
(4473,0,'platform',94),
(4474,0,'ballast',74),
(4475,0,'trial',77),
(4476,0,'ledger',78),
(4477,0,'silicon',68),
(4478,0,'brand',99),
(4479,0,'crude',60),
(4480,0,'cloud',92),
(4481,0,'ballast',82),
(4482,0,'rails',81),
(4483,0,'ledger',85),
(4484,0,'ledger',67),
(4485,0,'vault',99),
(4486,0,'cloud',99),
(4487,0,'platform',61),
(4488,0,'trial',100),
(4489,0,'ballast',92),
(4490,0,'bills',92),
(4491,0,'bills',73),
(4492,0,'rails',75),
(4493,0,'platform',90),
(4494,0,'cloud',100),
(4495,0,'silicon',60),
(4496,0,'shelf',96),
(4497,0,'ledger',79),
(4498,0,'shelf',92),
(4499,0,'shelf',70),
(4500,0,'bills',78),
(4501,0,'crude',89),
(4502,0,'trial',68),
(4503,0,'bills',84),
(4504,0,'grid',83),
(4505,0,'claims',90),
(4506,0,'ledger',79),
(4507,0,'cloud',87),
(4508,0,'vault',80),
(4509,0,'grid',88),
(4510,0,'ballast',74),
(4511,0,'bills',76),
(4512,0,'brand',68),
(4513,0,'grid',72),
(4514,0,'vault',76),
(4515,0,'brand',74),
(4516,0,'vault',94),
(4517,0,'claims',91),
(4518,0,'ballast',84),
(4519,0,'ballast',85),
(4520,0,'cloud',92),
(4521,0,'bills',83),
(4522,0,'claims',91),
(4523,0,'claims',77),
(4524,0,'grid',96),
(4525,0,'trial',80),
(4526,0,'brand',95),
(4527,0,'claims',97),
(4528,0,'grid',72),
(4529,0,'platform',68),
(4530,0,'ballast',83),
(4531,0,'grid',95),
(4532,0,'rails',100),
(4533,0,'silicon',89),
(4534,0,'crude',62),
(4535,0,'brand',77),
(4536,0,'shelf',88),
(4537,0,'shelf',70),
(4538,0,'shelf',69),
(4539,0,'shelf',79),
(4540,0,'shelf',72),
(4541,0,'ballast',95),
(4542,0,'claims',68),
(4543,0,'rails',100),
(4544,0,'grid',78),
(4545,0,'claims',75),
(4546,0,'crude',92),
(4547,0,'brand',82),
(4548,0,'shelf',71),
(4549,0,'vault',73),
(4550,0,'shelf',77),
(4551,0,'vault',91),
(4552,0,'cloud',81),
(4553,0,'grid',68),
(4554,0,'ledger',88),
(4555,0,'ledger',87),
(4556,0,'grid',63),
(4557,0,'bills',97),
(4558,0,'silicon',74),
(4559,0,'cloud',81),
(4560,0,'claims',96),
(4561,0,'ledger',77),
(4562,0,'trial',74),
(4563,0,'trial',89),
(4564,0,'rails',61),
(4565,0,'brand',84),
(4566,0,'shelf',96),
(4567,0,'trial',70),
(4568,0,'bills',92),
(4569,0,'trial',72),
(4570,0,'brand',67),
(4571,0,'platform',74),
(4572,0,'ledger',71),
(4573,0,'bills',62),
(4574,0,'vault',97),
(4575,0,'brand',83),
(4576,0,'grid',79),
(4577,0,'vault',90),
(4578,0,'vault',78),
(4579,0,'ballast',80),
(4580,0,'bills',88),
(4581,0,'ballast',92),
(4582,0,'crude',78),
(4583,0,'silicon',90),
(4584,0,'vault',63),
(4585,0,'bills',64),
(4586,0,'brand',68),
(4587,0,'cloud',82),
(4588,0,'platform',66),
(4589,0,'silicon',69),
(4590,0,'vault',93),
(4591,0,'bills',66),
(4592,0,'ballast',68),
(4593,0,'ledger',82),
(4594,0,'vault',99),
(4595,0,'ledger',90),
(4596,0,'grid',92),
(4597,0,'trial',92),
(4598,0,'cloud',70),
(4599,0,'trial',90),
(4600,0,'platform',81),
(4601,0,'grid',85),
(4602,0,'shelf',66),
(4603,0,'bills',79),
(4604,0,'grid',92),
(4605,0,'bills',63),
(4606,0,'shelf',67),
(4607,0,'platform',75),
(4608,0,'vault',100),
(4609,0,'trial',94),
(4610,0,'platform',73),
(4611,0,'ballast',71),
(4612,0,'bills',87),
(4613,0,'shelf',82),
(4614,0,'claims',96),
(4615,0,'trial',75),
(4616,0,'silicon',62),
(4617,0,'vault',61),
(4618,0,'brand',77),
(4619,0,'brand',86),
(4620,0,'silicon',66),
(4621,0,'brand',97),
(4622,0,'cloud',80),
(4623,0,'trial',75),
(4624,0,'grid',87),
(4625,0,'shelf',72),
(4626,0,'rails',89),
(4627,0,'rails',87),
(4628,0,'bills',87),
(4629,0,'platform',70),
(4630,0,'platform',93),
(4631,0,'bills',65),
(4632,0,'brand',69),
(4633,0,'shelf',87),
(4634,0,'vault',61),
(4635,0,'silicon',69),
(4636,0,'ballast',68),
(4637,0,'shelf',78),
(4638,0,'bills',91),
(4639,0,'ballast',96),
(4640,0,'platform',90),
(4641,0,'ballast',63),
(4642,0,'ledger',99),
(4643,0,'ballast',92),
(4644,0,'rails',88),
(4645,0,'cloud',98),
(4646,0,'trial',77),
(4647,0,'bills',91),
(4648,0,'trial',85),
(4649,0,'trial',77),
(4650,0,'rails',84),
(4651,0,'silicon',88),
(4652,0,'vault',80),
(4653,0,'shelf',69),
(4654,0,'platform',98),
(4655,0,'vault',77),
(4656,0,'shelf',96),
(4657,0,'grid',73),
(4658,0,'rails',72),
(4659,0,'cloud',97),
(4660,0,'grid',82),
(4661,0,'cloud',93),
(4662,0,'brand',92),
(4663,0,'rails',77),
(4664,0,'ledger',82),
(4665,0,'vault',69),
(4666,0,'vault',83),
(4667,0,'ballast',98),
(4668,0,'bills',62),
(4669,0,'ballast',67),
(4670,0,'silicon',77),
(4671,0,'ballast',94),
(4672,0,'rails',76),
(4673,0,'degen',71),
(4674,0,'platform',91),
(4675,0,'cloud',60),
(4676,0,'ballast',96),
(4677,0,'ballast',71),
(4678,0,'trial',61),
(4679,0,'ledger',95),
(4680,0,'rails',67),
(4681,0,'rails',73),
(4682,0,'vault',99),
(4683,0,'crude',95),
(4684,0,'platform',67),
(4685,0,'crude',67),
(4686,0,'crude',87),
(4687,0,'crude',72),
(4688,0,'shelf',66),
(4689,0,'platform',95),
(4690,0,'shelf',78),
(4691,0,'claims',62),
(4692,0,'bills',78),
(4693,0,'bills',92),
(4694,0,'vault',81),
(4695,0,'vault',79),
(4696,0,'vault',99),
(4697,0,'brand',92),
(4698,0,'bills',61),
(4699,0,'trial',86),
(4700,0,'ballast',92),
(4701,0,'bills',79),
(4702,0,'bills',98),
(4703,0,'brand',75),
(4704,0,'bills',84),
(4705,0,'ballast',87),
(4706,0,'ballast',62),
(4707,0,'vault',67),
(4708,0,'ledger',79),
(4709,0,'ballast',83),
(4710,0,'ledger',95),
(4711,0,'ledger',88),
(4712,0,'trial',98),
(4713,0,'crude',90),
(4714,0,'rails',97),
(4715,0,'ballast',80),
(4716,0,'brand',91),
(4717,0,'vault',96),
(4718,0,'brand',74),
(4719,0,'crude',72),
(4720,0,'bills',83),
(4721,0,'ballast',67),
(4722,0,'brand',84),
(4723,0,'trial',62),
(4724,0,'shelf',63),
(4725,0,'crude',65),
(4726,0,'trial',84),
(4727,0,'brand',62),
(4728,0,'ballast',60),
(4729,0,'claims',68),
(4730,0,'shelf',78),
(4731,0,'brand',83),
(4732,0,'shelf',92),
(4733,0,'grid',92),
(4734,0,'ballast',89),
(4735,0,'bills',80),
(4736,0,'shelf',89),
(4737,0,'ballast',64),
(4738,0,'ballast',71),
(4739,0,'ledger',95),
(4740,0,'bills',66),
(4741,0,'grid',72),
(4742,0,'shelf',71),
(4743,0,'bills',74),
(4744,0,'ballast',98),
(4745,0,'shelf',79),
(4746,0,'vault',70),
(4747,0,'claims',74),
(4748,0,'vault',80),
(4749,0,'ledger',82),
(4750,0,'ballast',61),
(4751,0,'vault',87),
(4752,0,'crude',98),
(4753,0,'rails',83),
(4754,0,'crude',66),
(4755,0,'grid',66),
(4756,0,'cloud',98),
(4757,0,'trial',92),
(4758,0,'shelf',97),
(4759,0,'grid',65),
(4760,0,'shelf',64),
(4761,0,'ledger',82),
(4762,0,'ballast',96),
(4763,0,'crude',75),
(4764,0,'vault',68),
(4765,0,'grid',78),
(4766,0,'cloud',74),
(4767,0,'shelf',82),
(4768,0,'bills',96),
(4769,0,'crude',81),
(4770,0,'vault',87),
(4771,0,'rails',79),
(4772,0,'ballast',65),
(4773,0,'vault',100),
(4774,0,'cloud',99),
(4775,0,'grid',99),
(4776,0,'ballast',81),
(4777,0,'teller',99),
(4778,0,'grid',99),
(4779,0,'grid',95),
(4780,0,'vault',99),
(4781,0,'bills',79),
(4782,0,'teller',64),
(4783,0,'bills',97),
(4784,0,'bills',64),
(4785,0,'vault',73),
(4786,0,'ballast',63),
(4787,0,'brand',81),
(4788,0,'brand',63),
(4789,0,'platform',83),
(4790,0,'grid',73),
(4791,0,'rails',61),
(4792,0,'cloud',100),
(4793,0,'ledger',89),
(4794,0,'claims',65),
(4795,0,'vault',75),
(4796,0,'claims',78),
(4797,0,'vault',69),
(4798,0,'platform',61),
(4799,0,'platform',65),
(4800,0,'silicon',99),
(4801,0,'ballast',68),
(4802,0,'silicon',74),
(4803,0,'rails',87),
(4804,0,'claims',76),
(4805,0,'ballast',70),
(4806,0,'ballast',66),
(4807,0,'cloud',91),
(4808,0,'crude',72),
(4809,0,'rails',95),
(4810,0,'grid',80),
(4811,0,'rails',94),
(4812,0,'shelf',97),
(4813,0,'platform',87),
(4814,0,'bills',96),
(4815,0,'bills',69),
(4816,0,'claims',92),
(4817,0,'platform',89),
(4818,0,'trial',79),
(4819,0,'crude',73),
(4820,0,'teller',63),
(4821,0,'shelf',89),
(4822,0,'ballast',67),
(4823,0,'ballast',86),
(4824,0,'rails',67),
(4825,0,'crude',96),
(4826,0,'platform',83),
(4827,0,'bills',100),
(4828,0,'crude',79),
(4829,0,'ledger',83),
(4830,0,'silicon',61),
(4831,0,'ballast',64),
(4832,0,'claims',71),
(4833,0,'ledger',74),
(4834,0,'rails',89),
(4835,0,'platform',96),
(4836,0,'crude',83),
(4837,0,'cloud',85),
(4838,0,'brand',97),
(4839,0,'rails',97),
(4840,0,'cloud',72),
(4841,0,'ballast',96),
(4842,0,'ballast',73),
(4843,0,'crude',80),
(4844,0,'silicon',72),
(4845,0,'teller',89),
(4846,0,'silicon',77),
(4847,0,'brand',69),
(4848,0,'ballast',100),
(4849,0,'trial',61),
(4850,0,'rails',67),
(4851,0,'shelf',83),
(4852,0,'ledger',87),
(4853,0,'cloud',85),
(4854,0,'brand',63),
(4855,0,'shelf',79),
(4856,0,'vault',78),
(4857,0,'platform',77),
(4858,0,'degen',71),
(4859,0,'grid',85),
(4860,0,'ledger',82),
(4861,0,'bills',84),
(4862,0,'claims',85),
(4863,0,'ballast',90),
(4864,0,'trial',100),
(4865,0,'brand',70),
(4866,0,'claims',84),
(4867,0,'cloud',70),
(4868,0,'grid',95),
(4869,0,'silicon',61),
(4870,0,'crude',76),
(4871,0,'shelf',95),
(4872,0,'bills',76),
(4873,0,'cloud',95),
(4874,0,'degen',68),
(4875,0,'shelf',60),
(4876,0,'vault',93),
(4877,0,'shelf',70),
(4878,0,'platform',63),
(4879,0,'teller',90),
(4880,0,'platform',87),
(4881,0,'ledger',100),
(4882,0,'ballast',88),
(4883,0,'crude',94),
(4884,0,'shelf',96),
(4885,0,'crude',100),
(4886,0,'cloud',78),
(4887,0,'brand',68),
(4888,0,'ballast',98),
(4889,0,'silicon',63),
(4890,0,'cloud',73),
(4891,0,'grid',80),
(4892,0,'ballast',84),
(4893,0,'bills',89),
(4894,0,'ballast',71),
(4895,0,'vault',64),
(4896,0,'grid',89),
(4897,0,'brand',84),
(4898,0,'trial',68),
(4899,0,'shelf',68),
(4900,0,'silicon',97),
(4901,0,'bills',77),
(4902,0,'grid',100),
(4903,0,'cloud',84),
(4904,0,'crude',73),
(4905,0,'crude',89),
(4906,0,'ledger',82),
(4907,0,'claims',68),
(4908,0,'shelf',63),
(4909,0,'claims',73),
(4910,0,'crude',86),
(4911,0,'rails',84),
(4912,0,'grid',73),
(4913,0,'trial',89),
(4914,0,'crude',66),
(4915,0,'shelf',77),
(4916,0,'platform',77),
(4917,0,'teller',70),
(4918,0,'platform',87),
(4919,0,'shelf',96),
(4920,0,'shelf',65),
(4921,0,'vault',70),
(4922,0,'bills',66),
(4923,0,'shelf',73),
(4924,0,'bills',71),
(4925,0,'ledger',76),
(4926,0,'shelf',97),
(4927,0,'ballast',98),
(4928,0,'grid',96),
(4929,0,'bills',90),
(4930,0,'rails',77),
(4931,0,'claims',92),
(4932,0,'cloud',73),
(4933,0,'ballast',60),
(4934,0,'cloud',98),
(4935,0,'platform',100),
(4936,0,'brand',95),
(4937,0,'ballast',89),
(4938,0,'rails',100),
(4939,0,'rails',68),
(4940,0,'cloud',95),
(4941,0,'platform',88),
(4942,0,'rails',78),
(4943,0,'grid',62),
(4944,0,'ballast',86),
(4945,0,'vault',72),
(4946,0,'silicon',81),
(4947,0,'platform',85),
(4948,0,'cloud',86),
(4949,0,'ballast',79),
(4950,0,'claims',93),
(4951,0,'ballast',84),
(4952,0,'shelf',84),
(4953,0,'bills',69),
(4954,0,'shelf',64),
(4955,0,'cloud',71),
(4956,0,'teller',98),
(4957,0,'teller',86),
(4958,0,'claims',92),
(4959,0,'ballast',64),
(4960,0,'shelf',76),
(4961,0,'shelf',91),
(4962,0,'shelf',98),
(4963,0,'ballast',94),
(4964,0,'vault',84),
(4965,0,'vault',68),
(4966,0,'cloud',73),
(4967,0,'platform',71),
(4968,0,'rails',89),
(4969,0,'shelf',81),
(4970,0,'grid',79),
(4971,0,'bills',83),
(4972,0,'platform',82),
(4973,0,'claims',92),
(4974,0,'platform',75),
(4975,0,'shelf',82),
(4976,0,'trial',73),
(4977,0,'trial',82),
(4978,0,'brand',96),
(4979,0,'ledger',79),
(4980,0,'ballast',83),
(4981,0,'grid',96),
(4982,0,'vault',95),
(4983,0,'brand',96),
(4984,0,'brand',70),
(4985,0,'ledger',85),
(4986,0,'degen',74),
(4987,0,'ledger',69),
(4988,0,'ledger',78),
(4989,0,'rails',97),
(4990,0,'platform',64),
(4991,0,'ledger',64),
(4992,0,'vault',75),
(4993,0,'ledger',70),
(4994,0,'silicon',96),
(4995,0,'cloud',86),
(4996,0,'cloud',76),
(4997,0,'cloud',87),
(4998,0,'trial',89),
(4999,0,'ballast',91);


-- ---------------------------------------------------------------------------
-- THE APY RECONCILIATION
-- ---------------------------------------------------------------------------
--
-- `blendedApy` is the MEAN of a worker's effective rates — deliberately a mean
-- and not a sum, because more skills means more desks and more diversification
-- rather than a flat multiple of the yield. This block recomputes that mean in
-- exact decimal arithmetic from the rows above plus public.skills, and compares
-- it to the apy the generator wrote in 20260806090300.
--
-- It is the most valuable assertion in the seed, because it is the only one that
-- cross-checks two independently emitted files against a third table. A skill
-- assigned to the wrong serial shifts a blended rate by whole percentage points;
-- a truncated skills file leaves a worker short a desk and drops its mean. Both
-- are invisible to a row count and neither survives this.
--
-- The tolerance is one unit in the last stored place. `apy` is numeric(8,6) and
-- the generator rounds a float64 mean into it, so the two can differ by up to
-- half of 1e-6 by construction — the generator measures that drift and refuses to
-- emit if it ever exceeds it. Anything larger than 1e-6 is not rounding.
do $$
declare
  v_rows integer;
  v_bad  integer;
  v_rec  record;
begin
  select count(*) into v_rows from public.xployee_skills;
  if v_rows <> 7900 then
    raise exception 'seeded % skill rows, expected 7900', v_rows;
  end if;

  -- Every worker holds exactly as many skills as its tier says. The primary key
  -- stops a slot being written twice and the unique constraint stops a skill
  -- being held twice; neither can see a worker that is simply short one row.
  select count(*) into v_bad from (
    select x.id
      from public.xployees x
      left join public.xployee_skills xs on xs.xployee_id = x.id
     group by x.id, x.skills
    having count(xs.slot) <> x.skills
  ) d;
  if v_bad > 0 then
    raise exception '% xployees hold the wrong number of skills for their tier', v_bad;
  end if;

  -- Slots are 0..n-1 with no gaps, so "the third skill" means the same thing to
  -- the database and to the sheet that renders it.
  select count(*) into v_bad from (
    select xs.xployee_id
      from public.xployee_skills xs
     group by xs.xployee_id
    having min(xs.slot) <> 0 or max(xs.slot) <> count(*) - 1
  ) d;
  if v_bad > 0 then
    raise exception '% xployees have gaps in their skill slots', v_bad;
  end if;

  for v_rec in
    select x.id,
           x.apy as stored,
           avg(s.base_apy * xs.proficiency_pct / 100) as computed
      from public.xployees x
      join public.xployee_skills xs on xs.xployee_id = x.id
      join public.skills s          on s.id = xs.skill_id
     group by x.id, x.apy
    having abs(x.apy - avg(s.base_apy * xs.proficiency_pct / 100)) > 0.000001
     limit 5
  loop
    raise exception 'xployee % stores apy % but its desks blend to %',
      public.serial_label(v_rec.id), v_rec.stored, round(v_rec.computed, 8);
  end loop;
end;
$$;

-- Now that every worker has its desks, the apy column can stop being nullable.
-- Left open until this point on purpose: a NOT NULL declared before the seed
-- would have to be satisfied by whichever file happened to load first, and the
-- apy is only meaningful once the rows it is the mean of exist.
alter table public.xployees alter column apy set not null;
alter table public.xployees alter column tier set not null;
alter table public.xployees alter column skills set not null;
alter table public.xployees alter column principal set not null;
alter table public.xployees alter column art_seed set not null;

-- A note for anyone reading the migrations in order rather than as one push:
-- `art_seed` becoming NOT NULL breaks the INSERT branch of the ORIGINAL
-- `record_simulated_sale` from 20260805120100, which upserts (id, owner) and
-- supplies no art seed. That branch is unreachable — every serial exists from
-- 20260806090300, so the upsert always takes its UPDATE path — and the function
-- is rewritten in 20260806090800 into an update-only writer that raises on an
-- unknown serial. It also has no caller: nothing in this backend invokes it, by
-- design, because an unauthenticated endpoint that inserts sale rows would let
-- anyone reassign any xployee. The window between these two migrations is inside
-- a single `db push`.

comment on column public.xployees.apy is
  'Blended annual rate: the MEAN of this worker''s effective desk rates. Reconciled against public.xployee_desks at seed time to one unit in the last stored place.';


-- =========================================================================
-- SECTION 10 of 18 — 20260806090500_seed_xnet_genesis.sql
-- =========================================================================

-- xNFTs index — seed: the genesis holding.
--
-- 1 xployee: #0000 X-RATED, held by the project wallet.
--
-- GENERATED — do not edit by hand. Run:
--   npx vite-node scripts/gen-genesis-seed.ts
--
-- This is the whole shipped state of the index. Everything else a visitor sees
-- — listings, other wallets, activity, earnings history — is absent because it
-- has not happened yet. Two earlier versions of this file seeded 512 xployees
-- over 97 invented wallets and then 35 over one; both claimed a history the
-- protocol did not have, and none of those addresses existed.
--
-- Rarity is positional, so serial 0 is the first X-RATED in the supply. The
-- hire timestamp is protocol genesis, so this worker opens with zero accrued
-- yield and earns from day one like every xployee minted after it.
--
-- Ownership is a placeholder until an operator runs assign_genesis_crew().

create table if not exists public.genesis_crew (
  serial integer primary key references public.xployees (id),
  owner text not null,
  hired_at bigint not null
);

alter table public.genesis_crew enable row level security;

drop policy if exists genesis_crew_read on public.genesis_crew;
create policy genesis_crew_read
  on public.genesis_crew for select to anon, authenticated using (true);

-- The policy alone is not enough. It decides which ROWS a role may see; the
-- GRANT decides whether the role may touch the table at all, and Postgres
-- checks the grant first. Without this, a read comes back as
--   401  42501  permission denied for table genesis_crew
-- which looks like an auth failure and is a missing privilege.
grant select on public.genesis_crew to anon, authenticated;

-- Denied twice, at two layers, and both are needed. The revoke is grant-level;
-- the restrictive policies are the RLS-level denial, and they AND together with
-- everything else so `false` is final. Every other table in the schema carries
-- this trio, and 20260806091100_rls_policies.sql ends with an assertion that
-- walks every table in `public` and raises if one is missing it — so a table
-- with only the revoke aborts that migration with
--   P0001: table public.genesis_crew is missing a restrictive write denial
revoke insert, update, delete on public.genesis_crew from anon, authenticated;

create policy "genesis_crew accepts no client insert" on public.genesis_crew
  as restrictive for insert to anon, authenticated with check (false);
create policy "genesis_crew accepts no client update" on public.genesis_crew
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "genesis_crew accepts no client delete" on public.genesis_crew
  as restrictive for delete to anon, authenticated using (false);

insert into public.genesis_crew (serial, owner, hired_at) values
  (0, 'GENESIS-UNASSIGNED', 1786060800000)
on conflict (serial) do nothing;

-- ---------------------------------------------------------------------------
-- Claiming the crew
-- ---------------------------------------------------------------------------
--
-- Run once, after setting dev_wallet in protocol_config:
--
--   select public.assign_genesis_crew();
--
-- Reads the wallet from config rather than taking it as an argument, so there is
-- no way to assign the crew to an address that is not the configured one.
create or replace function public.assign_genesis_crew()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target text;
  moved integer;
begin
  select dev_wallet into target from public.protocol_config where id = 1;

  if target is null or length(trim(target)) = 0 then
    raise exception 'dev_wallet is not set in protocol_config — set it first';
  end if;

  update public.genesis_crew set owner = target where owner <> target;
  get diagnostics moved = row_count;
  return moved;
end;
$$;

revoke all on function public.assign_genesis_crew() from anon, authenticated;


-- =========================================================================
-- SECTION 11 of 18 — 20260806090600_mint_control.sql
-- =========================================================================

-- xNFTs index — minting: the rate limit, the reservation, and the serial dealer.
--
-- ===========================================================================
-- THE THREAT
-- ===========================================================================
-- Rarity is positional and the supply is 5,000. At a low market cap, 10,000
-- $xNFT is cheap, so the attack is not clever: buy a pile of supply, mint in a
-- tight loop, and take the low serials before anybody else can get to them.
-- X-RATED is 150 units. A script that can mint once a second empties the rare
-- half of the reveal order in under an hour, and every honest buyer afterwards is
-- drawing from a pool somebody else has already picked over.
--
-- ===========================================================================
-- WHY THE LIMIT LIVES HERE AND NOWHERE ELSE
-- ===========================================================================
-- A client-side limit is not a limit. The mint transaction is a plain SPL
-- transfer that any wallet can build without this application's help, and the
-- Edge Function is reachable with a public anon key. The only party that sees
-- every request is Postgres, so the only place a limit can be enforced is
-- Postgres.
--
-- ===========================================================================
-- THE RULE THAT MAKES IT REAL, AND IT IS NOT THE OBVIOUS ONE
-- ===========================================================================
-- The limit is consumed when a serial is RESERVED, not when a burn is indexed.
--
-- That ordering is the whole design. A limit checked at ingest time is checked
-- after the tokens are already gone, so it cannot prevent anything — it can only
-- decide whether to hand over an xployee for a burn that already happened, which
-- is a refund problem rather than a rate limit. Worse, an attacker who does not
-- care about a pleasant experience simply skips the reservation and burns fifty
-- times in a row.
--
-- So both doors are closed, and they are closed with the same policy:
--
--   1. `reserve_mint` takes the rate limit and deals the serial BEFORE the buyer
--      burns anything. This is the limit. It is atomic, it is enforced by
--      constraints as well as by locks, and a refusal costs the caller nothing.
--   2. `record_mint` verifies the burn on chain and redeems that reservation. A
--      burn arriving with NO live reservation is dealt a serial only if the
--      policy would have allowed a reservation at that instant. Otherwise the
--      mint is still recorded — the tokens are gone and the chain says so, and a
--      backend that silently forgot a real burn would be stealing — but it is
--      recorded as `held`, with no serial, for the operator to resolve.
--
-- "Burn first, ask later" therefore buys an attacker nothing except burnt tokens
-- and a support ticket.
--
-- ===========================================================================
-- WHAT IS ACTUALLY ATOMIC, AND WHY EACH LAYER IS THERE
-- ===========================================================================
-- Not one check-then-insert anywhere. Five independent mechanisms, so that a bug
-- in any one of them still leaves the invariant standing:
--
--   1. `pg_advisory_xact_lock(MINT_GATE)` — one mint transaction at a time,
--      cluster-wide. Held to commit by the transaction that took it, so every
--      window count below is exact rather than a snapshot two callers can both
--      read as 99. The cost is that mints serialise; at a total supply of 5,000
--      that is not a cost worth optimising away for correctness.
--   2. `mint_reservations_one_live_per_wallet` — a partial UNIQUE index. Even
--      with the lock removed entirely, one wallet cannot hold two live
--      reservations. This is the constraint the brief asks for: not a check
--      somebody performs, a shape the data cannot take.
--   3. `mint_reservations_one_holder_per_position` / `_per_serial` — a serial can
--      be held by at most one reservation that still counts. Released positions
--      return to the pool and may legitimately appear again in a later row, which
--      is exactly why these are partial rather than plain uniques.
--   4. `for update skip locked` on the reveal pool — two concurrent dealers take
--      two different positions instead of racing for one. Redundant while the
--      gate lock is held; deliberately kept, because the day someone decides the
--      gate is too coarse, this is what stops the removal being a disaster.
--   5. `reveal_order.serial UNIQUE` — the permutation itself cannot contain a
--      duplicate, so "two mints received the same serial" is unrepresentable at
--      the storage layer no matter what every function above does.
--
-- ===========================================================================
-- CONFIGURABLE WITHOUT A CODE CHANGE
-- ===========================================================================
-- Every threshold is a column on `public.mint_policy`, a one-row table. An
-- operator changes a limit with an UPDATE from the dashboard; no deploy, no
-- migration, no function body edited. `paused` stops minting outright, which is
-- the control you want at 3am when something is going wrong and you do not yet
-- know what.
--
-- ===========================================================================
-- WHAT THIS DOES NOT DO
-- ===========================================================================
-- It does not stop a Sybil. Wallets are free, so a per-wallet cap is a cost
-- multiplier rather than a wall, and anyone claiming otherwise about a system
-- with no identity layer is selling something. What the GLOBAL cap does is bound
-- the RATE at which the collection can drain regardless of how many wallets are
-- involved — which converts "the rare serials were gone before anyone noticed"
-- into "the rare serials are draining and the operator has hours to respond".
-- That is the honest claim, and it is the one the numbers below are chosen for.

-- ---------------------------------------------------------------------------
-- The gate key
-- ---------------------------------------------------------------------------

-- An arbitrary but fixed advisory-lock key. A literal rather than
-- `hashtext('...')` so the value cannot change with a Postgres version or a
-- collation: every session must compute the same number or the mutex is not one.
create or replace function public.mint_gate_key()
returns bigint
language sql
immutable
parallel safe
set search_path = ''
as $$ select 7745110001::bigint $$;

comment on function public.mint_gate_key() is
  'Advisory lock key serialising the mint path. Any session taking it must use pg_advisory_xact_lock so it is released at commit or rollback — never pg_advisory_lock, which would survive a failed transaction and wedge minting until the connection died.';

-- ---------------------------------------------------------------------------
-- mint_policy — one row, every threshold
-- ---------------------------------------------------------------------------

create table public.mint_policy (
  -- Singleton by construction: a boolean primary key that must be true admits
  -- exactly one row, so there is no "which policy is in force" question to get
  -- wrong and no `where id = 1` to forget.
  id boolean primary key default true check (id),

  -- The kill switch. Checked first, before any counting, so it is also the
  -- fastest path through this file.
  paused       boolean not null default false,
  pause_reason text,

  -- Per wallet: the shortest gap between two reservations. Blunt, and blunt is
  -- the point — it turns a tight loop into a queue whatever else is true.
  wallet_cooldown_seconds integer not null default 90
    check (wallet_cooldown_seconds >= 0 and wallet_cooldown_seconds <= 86400),

  -- Per wallet: a rolling window and how many reservations fit in it. The window
  -- restarts from the first reservation in it rather than sliding continuously —
  -- cheaper, and the difference only ever favours the wallet.
  wallet_window_seconds integer not null default 86400 check (wallet_window_seconds > 0),
  wallet_window_limit   integer not null default 10    check (wallet_window_limit > 0),

  -- Across ALL wallets. This is the one that bounds the drain rate, and it is a
  -- true sliding window: every reservation created in the last
  -- `global_window_seconds` counts, whoever made it and whether or not they went
  -- on to burn. Abandoning a reservation therefore does not refund its budget,
  -- which is what stops reserve-and-drop being free.
  global_window_seconds integer not null default 3600 check (global_window_seconds > 0),
  global_window_limit   integer not null default 120  check (global_window_limit > 0),

  -- How long a reservation holds its serial before the position returns to the
  -- pool. Long enough to sign, send and confirm a Solana transaction several
  -- times over; short enough that an abandoned reservation is not a serial
  -- withdrawn from circulation for the afternoon.
  reservation_ttl_seconds integer not null default 900
    check (reservation_ttl_seconds >= 60 and reservation_ttl_seconds <= 3600),

  updated_at timestamptz not null default now(),
  -- Free text. Who changed it and why, for the operator's own benefit — nothing
  -- reads this.
  updated_note text
);

comment on table public.mint_policy is
  'Every mint threshold, in one row, changeable with an UPDATE. The defaults bound the drain rate at 120 serials/hour across the whole protocol and 10/day per wallet, with a 90-second floor between two reservations from one wallet.';
comment on column public.mint_policy.global_window_limit is
  'The number that actually protects the low serials. 120/hour against a 5,000 supply means the rarest 150 cannot be swept before an operator has had time to notice and pause.';
comment on column public.mint_policy.paused is
  'Refuses every new reservation immediately. Does NOT refuse an already-reserved burn — a buyer who has paid still gets their xployee, because pausing the mint must never become a way to take somebody''s tokens.';

insert into public.mint_policy (id) values (true);

-- ---------------------------------------------------------------------------
-- mint_rate_limits — the per-wallet counters
-- ---------------------------------------------------------------------------

create table public.mint_rate_limits (
  wallet public.base58_address primary key,

  -- The cooldown anchor. Set when a reservation is granted, not when a burn is
  -- indexed: the reservation is the scarce thing.
  last_reserved_at timestamptz,
  last_minted_at   timestamptz,

  -- The rolling window, as a start plus a count. Reset lazily on the next
  -- reservation rather than by a sweep, so there is no scheduled job whose
  -- failure quietly lifts the limit.
  window_started_at timestamptz not null default now(),
  window_count      integer not null default 0 check (window_count >= 0),

  lifetime_reservations integer not null default 0 check (lifetime_reservations >= 0),
  lifetime_mints        integer not null default 0 check (lifetime_mints >= 0),
  -- How often this wallet has been turned away. Not used by any decision; it is
  -- what tells an operator the difference between a busy day and somebody
  -- hammering the endpoint.
  refusals              integer not null default 0 check (refusals >= 0),

  first_seen_at timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.mint_rate_limits is
  'Per-wallet mint budget. Read and written only under the advisory gate lock plus a FOR UPDATE row lock, so two simultaneous reservations from one wallet cannot both see the same count.';

-- ---------------------------------------------------------------------------
-- mint_reservations — a held serial
-- ---------------------------------------------------------------------------

create table public.mint_reservations (
  id            uuid primary key default gen_random_uuid(),
  wallet        public.base58_address not null,
  draw_position integer not null references public.reveal_order (draw_position) on delete restrict,
  serial        integer not null,

  --   live     — holding its serial, waiting for a burn.
  --   redeemed — a verified burn arrived and the serial was assigned.
  --   expired  — the TTL passed with no burn; the position went back to the pool.
  --   released — given up deliberately (an operator, or a client that cancelled).
  status text not null default 'live'
    check (status in ('live', 'redeemed', 'expired', 'released')),

  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  redeemed_at timestamptz,
  -- The signature of the burn that redeemed it. Unique, so one transaction cannot
  -- redeem two reservations.
  mint_signature public.tx_signature unique,

  constraint mint_reservations_expiry_after_creation check (expires_at > created_at),
  -- A redeemed reservation names the transaction that redeemed it; anything else
  -- names none. Without this, `status` and `mint_signature` could disagree and a
  -- reader would have to guess which one meant it.
  constraint mint_reservations_redeemed_has_evidence check (
    (status = 'redeemed' and mint_signature is not null and redeemed_at is not null)
    or (status <> 'redeemed' and mint_signature is null and redeemed_at is null)
  )
);

-- LAYER 2. One live reservation per wallet, enforced by the index rather than by
-- the function that maintains it. This is what makes "two simultaneous mints
-- cannot both pass" true independently of the lock.
create unique index mint_reservations_one_live_per_wallet
  on public.mint_reservations (wallet) where status = 'live';

-- LAYER 3. A position, and its serial, may be held by at most one reservation
-- that still counts. Partial rather than plain: an expired or released
-- reservation returns its position to the pool, and the next buyer taking that
-- same position is correct behaviour, not a duplicate.
create unique index mint_reservations_one_holder_per_position
  on public.mint_reservations (draw_position) where status in ('live', 'redeemed');
create unique index mint_reservations_one_holder_per_serial
  on public.mint_reservations (serial) where status in ('live', 'redeemed');

create index mint_reservations_window_idx on public.mint_reservations (created_at desc);
create index mint_reservations_wallet_idx on public.mint_reservations (wallet, created_at desc);
create index mint_reservations_expiry_idx on public.mint_reservations (expires_at) where status = 'live';

comment on table public.mint_reservations is
  'A serial held for a wallet that has not burned yet. Creating one is what consumes the rate limit; redeeming one is what a verified burn does. Every reservation ever created counts against the global window whatever became of it, so reserve-and-abandon costs budget rather than refunding it.';

-- ---------------------------------------------------------------------------
-- mints — the columns an assignment needs
-- ---------------------------------------------------------------------------

alter table public.mints
  add column if not exists reservation_id uuid references public.mint_reservations (id) on delete set null,
  -- 'assigned' — a serial was dealt and public.xployees.owner now names the buyer.
  -- 'held'     — the burn is verified and recorded, and no serial was dealt. The
  --              tokens are gone; this row is the buyer's receipt and the
  --              operator's queue.
  add column if not exists assignment_status text not null default 'assigned',
  add column if not exists held_reason text;

alter table public.mints
  add constraint mints_assignment_status_known
    check (assignment_status in ('assigned', 'held'));

-- The two states have to be legible from the row alone. An 'assigned' row with no
-- xployee is a mint that quietly gave nothing; a 'held' row WITH one is a mint
-- that gave something the ledger says it did not.
alter table public.mints
  add constraint mints_assignment_matches_serial check (
    (assignment_status = 'assigned' and xployee_id is not null)
    or (assignment_status = 'held' and xployee_id is null and held_reason is not null)
  );

-- A serial is minted once, ever. The reveal order already guarantees a position
-- is dealt once; this says the same thing from the ledger's side, so the two
-- would have to be broken together to produce a double-mint.
create unique index if not exists mints_serial_minted_once
  on public.mints (xployee_id) where xployee_id is not null;

comment on column public.mints.xployee_id is
  'The serial this burn bought. No longer null in practice: the buyer reserves a serial before burning and record_mint redeems that reservation, so the assignment is a database fact rather than something the transaction had to carry. Null only on a ''held'' row.';
comment on column public.mints.assignment_status is
  'assigned = a serial was dealt. held = the burn is real and recorded but the policy would not deal a serial for it; the operator resolves these by hand. A held row is never silently discarded — the tokens are already burned.';

-- ---------------------------------------------------------------------------
-- release_expired_reservations
-- ---------------------------------------------------------------------------

-- Returns held serials to the pool. Called at the top of every reservation, so
-- the pool is correct at the moment it matters without depending on a scheduled
-- job — a cron that stops running would otherwise leak the collection one
-- abandoned reservation at a time, invisibly.
--
-- Scheduling it as well is still worth doing (see supabase/README.md): it keeps
-- the pool honest during a quiet period, so `reveal_order` read by the mint page
-- does not show serials that are only notionally held.
create or replace function public.release_expired_reservations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_freed integer := 0;
begin
  with dead as (
    update public.mint_reservations r
       set status = 'expired'
     where r.status = 'live'
       and r.expires_at <= now()
    returning r.draw_position
  )
  update public.reveal_order o
     set claimed_by = null,
         claimed_at = null,
         claim_kind = null
    from dead
   where o.draw_position = dead.draw_position
     -- Only a position still held BY a reservation goes back. A position that has
     -- since been minted is not a reservation's to release, and the guard means a
     -- late sweep cannot un-assign a serial somebody already owns.
     and o.claim_kind = 'reserved';

  get diagnostics v_freed = row_count;
  return v_freed;
end;
$$;

-- ---------------------------------------------------------------------------
-- reserve_mint — THE RATE LIMIT
-- ---------------------------------------------------------------------------

-- Returns jsonb rather than raising, because a refusal is an ordinary outcome
-- that the UI has to render as a sentence: "you can mint again in four minutes"
-- is information, not an error. Raising would also roll back the very counter
-- updates a refusal ought to record.
--
--   { ok: true,  reservation: { id, serial, draw_position, expires_at }, pool_remaining }
--   { ok: false, code, message, retry_after_seconds }
--
-- Codes: 'mint-paused', 'cooldown', 'wallet-window', 'global-window', 'sold-out'.
create or replace function public.reserve_mint(p_wallet text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_policy   public.mint_policy;
  v_limits   public.mint_rate_limits;
  v_existing public.mint_reservations;
  v_res      public.mint_reservations;
  v_position integer;
  v_serial   integer;
  v_global   integer;
  v_oldest   timestamptz;
  v_retry    integer;
  v_pool     integer;
begin
  if p_wallet is null or p_wallet !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$' then
    return jsonb_build_object(
      'ok', false, 'code', 'bad-wallet',
      'message', 'That is not a base58 Solana address. Nothing was reserved.'
    );
  end if;

  -- LAYER 1. Everything from here to commit is serialised. Taken before the
  -- policy is read so a concurrent operator UPDATE cannot land between the read
  -- and the decision it informs.
  perform pg_advisory_xact_lock(public.mint_gate_key());

  select * into v_policy from public.mint_policy where id;

  -- Abandoned reservations first: a caller who is about to be told the pool is
  -- empty deserves to be told that about the real pool.
  perform public.release_expired_reservations();

  if v_policy.paused then
    return jsonb_build_object(
      'ok', false, 'code', 'mint-paused',
      'message', coalesce(v_policy.pause_reason, 'Minting is paused. Nothing was reserved and nothing was charged.')
    );
  end if;

  -- An existing live reservation is RETURNED, not refused. A client that lost the
  -- response, refreshed the page, or retried a timeout must get its own serial
  -- back rather than be told it is rate limited by itself. The partial unique
  -- index would refuse the second insert anyway; answering here turns that from a
  -- constraint violation into the correct answer.
  select * into v_existing
    from public.mint_reservations
   where wallet = p_wallet and status = 'live'
   limit 1;
  if found then
    select count(*) into v_pool from public.reveal_order where claimed_at is null;
    return jsonb_build_object(
      'ok', true,
      'reused', true,
      'reservation', jsonb_build_object(
        'id', v_existing.id,
        'serial', v_existing.serial,
        'serial_label', public.serial_label(v_existing.serial),
        'tier', public.tier_for_id(v_existing.serial),
        'draw_position', v_existing.draw_position,
        'expires_at', v_existing.expires_at
      ),
      'pool_remaining', v_pool
    );
  end if;

  -- The per-wallet row. `insert ... on conflict do nothing` then `select ... for
  -- update` rather than a bare select: a wallet minting for the first time has no
  -- row, and two of its requests arriving together would otherwise both find
  -- nothing and both insert.
  insert into public.mint_rate_limits (wallet) values (p_wallet) on conflict (wallet) do nothing;
  select * into v_limits from public.mint_rate_limits where wallet = p_wallet for update;

  -- Cooldown.
  if v_limits.last_reserved_at is not null
     and v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) > now() then
    v_retry := ceil(extract(epoch from (
      v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) - now()
    )))::integer;
    update public.mint_rate_limits set refusals = refusals + 1, updated_at = now() where wallet = p_wallet;
    return jsonb_build_object(
      'ok', false, 'code', 'cooldown',
      'message', format('This wallet reserved a serial less than %s seconds ago. Nothing was reserved.',
                        v_policy.wallet_cooldown_seconds),
      'retry_after_seconds', v_retry
    );
  end if;

  -- Roll the window over if it has aged out. Lazily, so nothing depends on a
  -- sweep having run.
  if v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) <= now() then
    update public.mint_rate_limits
       set window_started_at = now(), window_count = 0, updated_at = now()
     where wallet = p_wallet
    returning * into v_limits;
  end if;

  if v_limits.window_count >= v_policy.wallet_window_limit then
    v_retry := ceil(extract(epoch from (
      v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) - now()
    )))::integer;
    update public.mint_rate_limits set refusals = refusals + 1, updated_at = now() where wallet = p_wallet;
    return jsonb_build_object(
      'ok', false, 'code', 'wallet-window',
      'message', format('This wallet has reserved %s serials in the last %s seconds, which is its limit. Nothing was reserved.',
                        v_limits.window_count, v_policy.wallet_window_seconds),
      'retry_after_seconds', greatest(v_retry, 1)
    );
  end if;

  -- The global window. A true sliding count over every reservation created in it,
  -- whatever became of that reservation — see the table comment for why an
  -- abandoned one still costs budget.
  select count(*), min(created_at) into v_global, v_oldest
    from public.mint_reservations
   where created_at > now() - make_interval(secs => v_policy.global_window_seconds);

  if v_global >= v_policy.global_window_limit then
    v_retry := greatest(1, ceil(extract(epoch from (
      v_oldest + make_interval(secs => v_policy.global_window_seconds) - now()
    )))::integer);
    update public.mint_rate_limits set refusals = refusals + 1, updated_at = now() where wallet = p_wallet;
    return jsonb_build_object(
      'ok', false, 'code', 'global-window',
      'message', format('The protocol has issued %s serials in the last %s seconds, which is the ceiling across all wallets. Nothing was reserved.',
                        v_global, v_policy.global_window_seconds),
      'retry_after_seconds', v_retry
    );
  end if;

  -- LAYER 4. Deal the lowest position still in the pool. `for update skip locked`
  -- inside the subquery so two dealers take two rows; `claimed_at is null` in the
  -- outer predicate as well, so a row that was claimed between the pick and the
  -- write updates nothing rather than overwriting somebody's claim.
  update public.reveal_order o
     set claimed_by = p_wallet,
         claimed_at = now(),
         claim_kind = 'reserved'
   where o.draw_position = (
     select i.draw_position
       from public.reveal_order i
      where i.claimed_at is null
      order by i.draw_position
      limit 1
      for update skip locked
   )
     and o.claimed_at is null
  returning o.draw_position, o.serial into v_position, v_serial;

  if v_position is null then
    return jsonb_build_object(
      'ok', false, 'code', 'sold-out',
      'message', 'Every serial in the collection has been dealt. Nothing was reserved.'
    );
  end if;

  insert into public.mint_reservations (wallet, draw_position, serial, expires_at)
  values (p_wallet, v_position, v_serial, now() + make_interval(secs => v_policy.reservation_ttl_seconds))
  returning * into v_res;

  update public.mint_rate_limits
     set last_reserved_at      = now(),
         window_count          = window_count + 1,
         lifetime_reservations = lifetime_reservations + 1,
         updated_at            = now()
   where wallet = p_wallet;

  select count(*) into v_pool from public.reveal_order where claimed_at is null;

  return jsonb_build_object(
    'ok', true,
    'reused', false,
    'reservation', jsonb_build_object(
      'id', v_res.id,
      'serial', v_res.serial,
      'serial_label', public.serial_label(v_res.serial),
      'tier', public.tier_for_id(v_res.serial),
      'draw_position', v_res.draw_position,
      'expires_at', v_res.expires_at
    ),
    'pool_remaining', v_pool
  );
end;
$$;

comment on function public.reserve_mint(text) is
  'THE rate limit. Takes the wallet''s budget and deals a serial before any burn happens. Returns jsonb — a refusal is an outcome the UI renders, not an exception.';

-- ---------------------------------------------------------------------------
-- release_mint_reservation
-- ---------------------------------------------------------------------------

-- A wallet giving up its own hold. Returns the position to the pool immediately
-- instead of waiting out the TTL — but deliberately does NOT refund the rate
-- limit, because a refund would make reserve/cancel/reserve a free way to reroll
-- a serial until a rare one came up. The reveal order is a lottery, and a lottery
-- you can redraw is not one.
create or replace function public.release_mint_reservation(p_wallet text, p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_position integer;
begin
  perform pg_advisory_xact_lock(public.mint_gate_key());

  update public.mint_reservations r
     set status = 'released'
   where r.id = p_reservation_id
     and r.wallet = p_wallet
     and r.status = 'live'
  returning r.draw_position into v_position;

  if v_position is null then
    return jsonb_build_object(
      'ok', false, 'code', 'not-found',
      'message', 'No live reservation of that id belongs to this wallet. Nothing was changed.'
    );
  end if;

  update public.reveal_order
     set claimed_by = null, claimed_at = null, claim_kind = null
   where draw_position = v_position and claim_kind = 'reserved';

  return jsonb_build_object('ok', true, 'released', v_position);
end;
$$;

-- ---------------------------------------------------------------------------
-- record_mint — the chain-verified write
-- ---------------------------------------------------------------------------

-- Called by `ingest-signature` and by nothing else. Every argument was read out
-- of a transaction that function fetched from RPC itself; none of them came from
-- a browser.
--
-- No `p_fee`. A mint is one transfer to the incinerator and pays nobody — see
-- 20260806090000, which nails `mints.fee` to zero so the absence is enforced
-- rather than assumed.
--
-- THE ORDER OF THE BRANCHES IS THE POLICY:
--
--   1. Already indexed? Return what was decided last time. Idempotent per
--      (signature, event_index) at the primary key, so a replay cannot deal a
--      second serial and cannot flip a held row to assigned.
--   2. A live reservation for this buyer? Redeem it. This is the honest path and
--      the only one that should ever run in practice.
--   3. No reservation, but the policy would allow one right now? Deal a serial
--      and charge the budget for it. Covers the buyer whose reservation expired
--      while their transaction was confirming.
--   4. Otherwise: record the burn as `held`. The tokens are gone and the chain
--      says so — refusing to write the row would be the backend forgetting real
--      money — but no serial is dealt, so "burn first, ask later" cannot outrun
--      the limit.
create or replace function public.record_mint(
  p_signature   text,
  p_event_index integer,
  p_slot        bigint,
  p_block_time  timestamptz,
  p_buyer       text,
  p_burned      text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing  public.mints;
  v_res       public.mint_reservations;
  v_policy    public.mint_policy;
  v_limits    public.mint_rate_limits;
  v_global    integer;
  v_position  integer;
  v_serial    integer;
  v_hired     timestamptz := coalesce(p_block_time, now());
  v_held      text;
begin
  perform pg_advisory_xact_lock(public.mint_gate_key());

  -- 1. Replay.
  select * into v_existing
    from public.mints
   where signature = p_signature and event_index = p_event_index;
  if found then
    return jsonb_build_object(
      'ok', true, 'outcome', 'duplicate',
      'assignment_status', v_existing.assignment_status,
      'xployee_id', v_existing.xployee_id,
      'serial_label', case when v_existing.xployee_id is null then null
                           else public.serial_label(v_existing.xployee_id) end
    );
  end if;

  select * into v_policy from public.mint_policy where id;
  perform public.release_expired_reservations();

  -- 2. Redeem the buyer's own hold. Ordered by expiry so the one closest to
  -- lapsing is settled first; there can only be one live row per wallet, so the
  -- ordering is belt and braces rather than a real choice.
  select * into v_res
    from public.mint_reservations
   where wallet = p_buyer and status = 'live'
   order by expires_at
   limit 1;

  if found then
    v_position := v_res.draw_position;
    v_serial   := v_res.serial;
    update public.mint_reservations
       set status = 'redeemed', redeemed_at = now(), mint_signature = p_signature
     where id = v_res.id;
  else
    -- 3. No hold. Would the policy have granted one at this instant?
    if v_policy.paused then
      v_held := 'Minting was paused when this burn was indexed, and no serial was held for this wallet.';
    else
      insert into public.mint_rate_limits (wallet) values (p_buyer) on conflict (wallet) do nothing;
      select * into v_limits from public.mint_rate_limits where wallet = p_buyer for update;

      if v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) <= now() then
        update public.mint_rate_limits
           set window_started_at = now(), window_count = 0, updated_at = now()
         where wallet = p_buyer
        returning * into v_limits;
      end if;

      select count(*) into v_global
        from public.mint_reservations
       where created_at > now() - make_interval(secs => v_policy.global_window_seconds);

      -- The cooldown is NOT applied here. It exists to stop a loop from forming,
      -- and a burn that has already landed is not a loop that can be stopped —
      -- charging a buyer for being 80 seconds early would take their tokens over
      -- a timing rule that has nothing left to protect. The two window caps ARE
      -- applied, because those are the ceilings that bound the drain.
      if v_limits.window_count >= v_policy.wallet_window_limit then
        v_held := format('This wallet has already taken %s of its %s serials for the current window.',
                         v_limits.window_count, v_policy.wallet_window_limit);
      elsif v_global >= v_policy.global_window_limit then
        v_held := format('The protocol issued %s serials in the last %s seconds, which is the ceiling across all wallets.',
                         v_global, v_policy.global_window_seconds);
      else
        update public.reveal_order o
           set claimed_by = p_buyer, claimed_at = now(), claim_kind = 'reserved'
         where o.draw_position = (
           select i.draw_position from public.reveal_order i
            where i.claimed_at is null
            order by i.draw_position
            limit 1
            for update skip locked
         )
           and o.claimed_at is null
        returning o.draw_position, o.serial into v_position, v_serial;

        if v_position is null then
          v_held := 'Every serial in the collection had been dealt when this burn was indexed.';
        else
          -- Recorded as a reservation redeemed in the same breath, so the audit
          -- trail is the same shape whichever branch produced it and the global
          -- window sees this serial the way it sees every other.
          insert into public.mint_reservations
            (wallet, draw_position, serial, expires_at, status, redeemed_at, mint_signature)
          values
            (p_buyer, v_position, v_serial,
             now() + make_interval(secs => v_policy.reservation_ttl_seconds),
             'redeemed', now(), p_signature)
          returning * into v_res;

          update public.mint_rate_limits
             set last_reserved_at      = now(),
                 window_count          = window_count + 1,
                 lifetime_reservations = lifetime_reservations + 1,
                 updated_at            = now()
           where wallet = p_buyer;
        end if;
      end if;
    end if;
  end if;

  -- 4. Write the mint, whichever way it went.
  if v_serial is null then
    insert into public.mints (
      signature, event_index, buyer, burned, slot, block_time,
      assignment_status, held_reason
    ) values (
      p_signature, p_event_index, p_buyer, p_burned, p_slot, p_block_time,
      'held', coalesce(v_held, 'No serial could be assigned to this burn.')
    );

    insert into public.mint_rate_limits (wallet) values (p_buyer) on conflict (wallet) do nothing;
    update public.mint_rate_limits
       set refusals = refusals + 1, updated_at = now()
     where wallet = p_buyer;

    return jsonb_build_object(
      'ok', true, 'outcome', 'inserted',
      'assignment_status', 'held',
      'held_reason', coalesce(v_held, 'No serial could be assigned to this burn.'),
      'xployee_id', null
    );
  end if;

  update public.reveal_order
     set claim_kind = 'minted', claimed_by = p_buyer
   where draw_position = v_position;

  update public.xployees
     set owner          = p_buyer,
         hired_at       = v_hired,
         mint_signature = p_signature
   where id = v_serial;

  insert into public.mints (
    signature, event_index, buyer, burned, xployee_id, slot, block_time,
    reservation_id, assignment_status
  ) values (
    p_signature, p_event_index, p_buyer, p_burned, v_serial, p_slot, p_block_time,
    v_res.id, 'assigned'
  );

  update public.mint_rate_limits
     set last_minted_at = now(),
         lifetime_mints = lifetime_mints + 1,
         updated_at     = now()
   where wallet = p_buyer;

  return jsonb_build_object(
    'ok', true, 'outcome', 'inserted',
    'assignment_status', 'assigned',
    'xployee_id', v_serial,
    'serial_label', public.serial_label(v_serial),
    'tier', public.tier_for_id(v_serial)
  );
end;
$$;

comment on function public.record_mint(text, integer, bigint, timestamptz, text, text) is
  'The chain-verified mint writer. Every argument comes from a transaction ingest-signature fetched itself. Idempotent per (signature, event_index); never discards a real burn, and never deals a serial the policy would have refused.';

-- ---------------------------------------------------------------------------
-- mint_availability — what the mint page needs to say
-- ---------------------------------------------------------------------------

-- Read-only. Answers "can this wallet mint, and if not, when?" without taking
-- any budget, so a page can poll it.
create or replace function public.mint_availability(p_wallet text default null)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_policy public.mint_policy;
  v_limits public.mint_rate_limits;
  v_res    public.mint_reservations;
  v_pool   integer;
  v_global integer;
  v_wait   integer := 0;
  v_code   text := 'ready';
begin
  select * into v_policy from public.mint_policy where id;
  select count(*) into v_pool from public.reveal_order where claimed_at is null;
  select count(*) into v_global
    from public.mint_reservations
   where created_at > now() - make_interval(secs => v_policy.global_window_seconds);

  if v_policy.paused then
    v_code := 'mint-paused';
  elsif v_pool = 0 then
    v_code := 'sold-out';
  elsif v_global >= v_policy.global_window_limit then
    v_code := 'global-window';
  end if;

  if p_wallet is not null then
    select * into v_limits from public.mint_rate_limits where wallet = p_wallet;
    select * into v_res
      from public.mint_reservations
     where wallet = p_wallet and status = 'live' and expires_at > now()
     limit 1;

    if v_code = 'ready' and v_limits.wallet is not null then
      if v_limits.last_reserved_at is not null
         and v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) > now() then
        v_code := 'cooldown';
        v_wait := ceil(extract(epoch from (
          v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) - now())))::integer;
      elsif v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) > now()
        and v_limits.window_count >= v_policy.wallet_window_limit then
        v_code := 'wallet-window';
        v_wait := ceil(extract(epoch from (
          v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) - now())))::integer;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'code', v_code,
    'paused', v_policy.paused,
    'pool_remaining', v_pool,
    'supply', public.max_supply(),
    'retry_after_seconds', greatest(v_wait, 0),
    'global_window_seconds', v_policy.global_window_seconds,
    'global_window_limit', v_policy.global_window_limit,
    'global_window_used', v_global,
    'wallet_window_seconds', v_policy.wallet_window_seconds,
    'wallet_window_limit', v_policy.wallet_window_limit,
    'wallet_window_used', coalesce(v_limits.window_count, 0),
    'wallet_cooldown_seconds', v_policy.wallet_cooldown_seconds,
    'reservation', case when v_res.id is null then null else jsonb_build_object(
      'id', v_res.id,
      'serial', v_res.serial,
      'serial_label', public.serial_label(v_res.serial),
      'tier', public.tier_for_id(v_res.serial),
      'expires_at', v_res.expires_at
    ) end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

-- Same rule as 20260805120100: PostgREST resolves /rpc/<fn> through the caller's
-- role, so revoking EXECUTE from anon is what stops the public key calling a
-- writer directly. `mint_availability` is read-only and would be harmless in anon
-- hands — it is still closed, because "harmless today" is how a read function
-- acquires a write branch six months later, and the Edge Function that needs it
-- already has the service role.
revoke all on function public.mint_gate_key() from public, anon, authenticated;
revoke all on function public.release_expired_reservations() from public, anon, authenticated;
revoke all on function public.reserve_mint(text) from public, anon, authenticated;
revoke all on function public.release_mint_reservation(text, uuid) from public, anon, authenticated;
revoke all on function public.record_mint(text, integer, bigint, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.mint_availability(text) from public, anon, authenticated;

-- `stamp_xployee_identity` is deliberately NOT revoked. It is a trigger function
-- and nothing can call it directly — a trigger has no argument list to invoke —
-- while revoking EXECUTE from PUBLIC on a trigger function is a known way to
-- produce "permission denied for function" from an ordinary write. Closing a door
-- that does not exist at the cost of one that does is a bad trade.

grant execute on function public.release_expired_reservations() to service_role;
grant execute on function public.reserve_mint(text) to service_role;
grant execute on function public.release_mint_reservation(text, uuid) to service_role;
grant execute on function public.record_mint(text, integer, bigint, timestamptz, text, text) to service_role;
grant execute on function public.mint_availability(text) to service_role;

-- The pure helpers stay callable by everyone: they read nothing, write nothing,
-- and a policy or a generated column that calls them has to be able to.
grant execute on function public.max_supply() to public;
grant execute on function public.tier_for_id(bigint) to public;
grant execute on function public.skills_for_tier(text) to public;
grant execute on function public.serial_label(bigint) to public;


-- =========================================================================
-- SECTION 12 of 18 — 20260806090700_identity.sql
-- =========================================================================

-- xNFTs index — identity: profiles, verified X handles, and wallet linking.
--
-- ===========================================================================
-- THE ONE RULE
-- ===========================================================================
-- An X handle is stored ONLY when it came out of a verified OAuth identity.
-- There is no code path that accepts a typed one, and that is enforced three
-- ways rather than asserted once:
--
--   1. `set_profile` — the writer a user's own edits go through — HAS NO
--      TWITTER PARAMETER. Not an ignored one, not a validated one: the argument
--      list does not contain a place to put a handle. A caller that wants to set
--      one has nothing to send it in, and a future contributor who adds one has
--      to change a function signature, which is a visible act.
--   2. `link_twitter_identity` takes an `auth.users` id and reads the handle out
--      of `auth.identities` itself. The handle is a value GoTrue wrote after
--      completing the OAuth exchange with X; nothing the browser sends reaches
--      that column.
--   3. `profiles_twitter_is_verified` — a check constraint making a handle
--      without a provider id, a verification timestamp AND an auth user
--      unrepresentable. Even a service-role INSERT cannot write a bare handle.
--
-- ===========================================================================
-- LINKING PROVES BOTH SIDES
-- ===========================================================================
-- A link is a claim about two things at once — "this X account and this Solana
-- wallet are the same person" — so one proof is not enough. Proving only the X
-- side lets anyone attach a stranger's wallet to their own account and inherit
-- its collection on every leaderboard. Proving only the wallet side lets anyone
-- attach a stranger's X handle to their own wallet and impersonate them.
--
--   X side      — a Supabase Auth session carrying a `twitter` identity. GoTrue
--                 completed the OAuth exchange; the browser cannot fabricate it.
--   Wallet side — an ed25519 signature, made by the wallet's own key, over a
--                 nonce THIS SERVER issued. Not a nonce the client chose: a
--                 client-chosen nonce is a signature an attacker can have
--                 collected somewhere else and replayed.
--
-- Both are consumed in one call. `complete_wallet_link` is reachable only by the
-- service role, and it is called only after `link-wallet` has verified the
-- signature — the same trust shape as `record_mint`, which the database also
-- takes on faith from a function that did the checking. The database's job is to
-- make the *result* unforgeable and unrepeatable; the Edge Function's job is to
-- do the cryptography. Neither can cover for the other.
--
-- ===========================================================================
-- WHY IDENTITY IS NEEDED AT ALL
-- ===========================================================================
-- Every social and marketplace writer after this migration has to answer "who is
-- acting?" without believing a request body. `public.actor_wallet(uid)` is that
-- answer: it resolves a session to the wallet that PROVED it owns that session,
-- so no writer ever takes a wallet address as a parameter from a caller. That is
-- the same discipline as "destinations read from configuration, never caller
-- parameters", applied to identity instead of to money.

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table public.profiles (
  wallet public.base58_address primary key,

  -- Display name. User-typed and deliberately so — it is a nickname, not a claim
  -- about anything outside this application. Same shape as USERNAME_RE in
  -- src/lib/profile.ts.
  handle text check (handle is null or handle ~ '^[A-Za-z0-9_]{3,20}$'),
  bio    text check (bio is null or length(bio) <= 160),

  -- One of the owner's own xployees, rendered as their avatar. Not a foreign key
  -- with a cascade: an xployee is never deleted, and a sold one should leave a
  -- stale avatar to be corrected rather than a profile that vanished.
  avatar_xployee_id bigint references public.xployees (id) on delete set null,

  -- ---- the verified half ----
  --
  -- All four move together or not at all. `twitter_user_id` is X's numeric id,
  -- which is what actually identifies an account — a handle can be released and
  -- taken by somebody else, and a link keyed on the handle would silently follow
  -- it to the new owner.
  twitter_user_id     text unique,
  twitter_handle      text check (twitter_handle is null or twitter_handle ~ '^[A-Za-z0-9_]{1,15}$'),
  twitter_verified_at timestamptz,
  auth_user_id        uuid unique references auth.users (id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- THE CONSTRAINT THAT MAKES "VERIFIED ONLY" STRUCTURAL. A handle exists if and
  -- only if the provider id, the verification timestamp and the auth user all
  -- exist alongside it. There is no arrangement of columns that spells "handle
  -- somebody typed".
  constraint profiles_twitter_is_verified check (
    (twitter_handle is null and twitter_user_id is null and twitter_verified_at is null)
    or (twitter_handle is not null and twitter_user_id is not null
        and twitter_verified_at is not null and auth_user_id is not null)
  )
);

-- Handles are compared the way people read them. A unique index on lower() rather
-- than a unique column, so 'Deskrunner' cannot be registered next to 'deskrunner'
-- and used to impersonate it.
create unique index profiles_handle_ci_idx on public.profiles (lower(handle)) where handle is not null;
create index profiles_twitter_idx on public.profiles (lower(twitter_handle)) where twitter_handle is not null;

comment on table public.profiles is
  'Per-wallet profile. handle and bio are user-typed; twitter_handle is copied out of a verified OAuth identity by link_twitter_identity and can be written no other way — see profiles_twitter_is_verified.';
comment on column public.profiles.twitter_handle is
  'VERIFIED ONLY. Copied from auth.identities.identity_data after GoTrue completed the OAuth exchange with X. No writer in this schema accepts a handle as an argument.';
comment on column public.profiles.twitter_user_id is
  'X''s numeric account id. The link is keyed on this rather than on the handle, because a handle can be released and re-registered by somebody else and a handle-keyed link would follow it.';

-- ---------------------------------------------------------------------------
-- wallet_identities — the proof, kept
-- ---------------------------------------------------------------------------

-- The evidence behind a link, separate from the profile that displays it. Kept
-- because a link is a security assertion and an assertion with no record of what
-- justified it cannot be audited or revoked with confidence.
create table public.wallet_identities (
  wallet          public.base58_address primary key,
  auth_user_id    uuid not null unique references auth.users (id) on delete cascade,
  provider        text not null default 'twitter' check (provider = 'twitter'),
  twitter_user_id text not null unique,
  twitter_handle  text not null,
  -- The exact nonce that was signed, and the signature over it. Kept so a
  -- disputed link can be re-verified offline from this row alone.
  proof_nonce     text not null unique,
  proof_signature text not null,
  linked_at       timestamptz not null default now()
);

comment on table public.wallet_identities is
  'One wallet to one X account, unique in both directions. Holds the nonce and signature that proved the wallet side, so a link can be re-verified from the row rather than taken on trust.';

-- ---------------------------------------------------------------------------
-- wallet_link_challenges — the nonce
-- ---------------------------------------------------------------------------

-- A nonce is a secret until it is used, so this is the one table in the schema
-- that anon cannot read at all (see 20260806091100). Publishing the statement a
-- wallet is about to sign would not break the scheme by itself — the signature
-- is what matters — but a readable challenge table hands an attacker every
-- in-flight link attempt and the wallet each one is for.
create table public.wallet_link_challenges (
  nonce        text primary key check (length(nonce) between 32 and 128),
  wallet       public.base58_address not null,
  auth_user_id uuid not null references auth.users (id) on delete cascade,
  -- The exact text the wallet signs. Stored rather than recomputed so
  -- verification compares against the bytes that were actually issued — a
  -- statement rebuilt at verification time from a template is a statement that
  -- can be rebuilt differently.
  statement    text not null,
  issued_at    timestamptz not null default now(),
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  constraint wallet_link_challenges_expiry check (expires_at > issued_at)
);

create index wallet_link_challenges_user_idx on public.wallet_link_challenges (auth_user_id, issued_at desc);
create index wallet_link_challenges_sweep_idx on public.wallet_link_challenges (expires_at) where consumed_at is null;

comment on table public.wallet_link_challenges is
  'Server-issued nonces for wallet proof-of-ownership. Single use: consumed_at is set inside the same transaction that writes the link, so a replayed signature finds a spent challenge.';

-- ---------------------------------------------------------------------------
-- wallets.twitter — closed
-- ---------------------------------------------------------------------------

-- `public.wallets` predates this migration and carries a free-text `twitter`
-- column that any writer could once have filled in with anything. It is now a
-- mirror of the verified handle and nothing else, enforced by a trigger because a
-- check constraint cannot look at another table.
--
-- The column is kept rather than dropped for the same reason `mints.fee` was:
-- `src/lib/supabase.ts` maps it, and a dropped column changes the shape
-- PostgREST returns. What changes is that it can no longer hold a claim.
create or replace function public.guard_wallet_twitter()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.twitter is not null and not exists (
    select 1 from public.profiles p
     where p.wallet = new.address
       and p.twitter_handle = new.twitter
       and p.twitter_verified_at is not null
  ) then
    raise exception 'wallets.twitter mirrors a verified X handle from public.profiles; it cannot be set to a value nobody proved';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger wallets_twitter_must_be_verified
  before insert or update on public.wallets
  for each row execute function public.guard_wallet_twitter();

comment on column public.wallets.twitter is
  'A MIRROR of profiles.twitter_handle, maintained by link_twitter_identity. The wallets_twitter_must_be_verified trigger refuses any value that is not a verified handle already on the matching profile.';

-- ---------------------------------------------------------------------------
-- actor_wallet — who is acting
-- ---------------------------------------------------------------------------

-- The single answer to "which wallet is this session?" Every writer in the
-- migrations after this one calls it and none of them takes a wallet address as
-- a parameter, so there is no writer a caller can point at somebody else's
-- holdings.
--
-- Returns null rather than raising when the session has no linked wallet: an
-- unlinked user is an ordinary state (they signed in with X and have not proved a
-- wallet yet), and the callers turn it into a typed refusal with a sentence
-- attached.
create or replace function public.actor_wallet(p_user_id uuid)
returns text
language sql
security definer
stable
set search_path = ''
as $$
  select wallet from public.wallet_identities where auth_user_id = p_user_id
$$;

comment on function public.actor_wallet(uuid) is
  'Resolves an auth session to the wallet that proved it owns that session. The only sanctioned way for a writer to learn who is acting — never take a wallet from a request body.';

-- ---------------------------------------------------------------------------
-- set_profile — the user-typed half
-- ---------------------------------------------------------------------------

-- NOTE THE ARGUMENT LIST. There is no twitter parameter and there must never be
-- one. Adding it is the single change that would break the guarantee at the top
-- of this file, so it is called out here where anyone editing the signature will
-- read it.
--
-- The wallet is resolved from the session, not passed. An avatar has to be an
-- xployee the wallet actually owns, checked here rather than in the client,
-- because "show me as somebody else's X-RATED" is exactly the kind of harmless
-- little lie that a leaderboard makes not harmless.
create or replace function public.set_profile(
  p_user_id uuid,
  p_handle  text,
  p_bio     text,
  p_avatar_xployee_id bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
  v_handle text := nullif(btrim(coalesce(p_handle, '')), '');
  v_bio    text := nullif(btrim(coalesce(p_bio, '')), '');
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object(
      'ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Prove the wallet first; nothing was saved.'
    );
  end if;

  if v_handle is not null and v_handle !~ '^[A-Za-z0-9_]{3,20}$' then
    return jsonb_build_object(
      'ok', false, 'code', 'bad-handle',
      'message', 'A handle is 3–20 characters: letters, numbers or underscore. Nothing was saved.'
    );
  end if;
  if v_bio is not null and length(v_bio) > 160 then
    return jsonb_build_object(
      'ok', false, 'code', 'bad-bio',
      'message', 'A bio is 160 characters or fewer. Nothing was saved.'
    );
  end if;

  if p_avatar_xployee_id is not null and not exists (
    select 1 from public.xployees x where x.id = p_avatar_xployee_id and x.owner = v_wallet
  ) then
    return jsonb_build_object(
      'ok', false, 'code', 'avatar-not-owned',
      'message', 'An avatar has to be an xployee this wallet owns. Nothing was saved.'
    );
  end if;

  if v_handle is not null and exists (
    select 1 from public.profiles p
     where lower(p.handle) = lower(v_handle) and p.wallet <> v_wallet
  ) then
    return jsonb_build_object(
      'ok', false, 'code', 'handle-taken',
      'message', 'That handle belongs to another wallet. Nothing was saved.'
    );
  end if;

  insert into public.profiles (wallet, handle, bio, avatar_xployee_id)
  values (v_wallet, v_handle, v_bio, p_avatar_xployee_id)
  on conflict (wallet) do update
     set handle            = excluded.handle,
         bio               = excluded.bio,
         avatar_xployee_id = excluded.avatar_xployee_id,
         updated_at        = now();

  -- Mirror into public.wallets, which is what src/lib/supabase.ts reads today.
  -- One transaction, so the two cannot end up describing different people.
  insert into public.wallets (address, handle, bio)
  values (v_wallet, v_handle, v_bio)
  on conflict (address) do update
     set handle = excluded.handle,
         bio    = excluded.bio;

  return jsonb_build_object('ok', true, 'wallet', v_wallet, 'handle', v_handle);
end;
$$;

-- ---------------------------------------------------------------------------
-- Wallet linking
-- ---------------------------------------------------------------------------

-- Step one: issue the nonce.
--
-- The nonce comes from the Edge Function's CSPRNG rather than from
-- `gen_random_uuid()` here, so that the value the wallet signs and the value the
-- verifier compares against travel together through one piece of code. The TTL is
-- short — a challenge is a thing you answer in the next minute, and a long-lived
-- one is a signature an attacker has longer to obtain by other means.
create or replace function public.issue_wallet_link_challenge(
  p_user_id     uuid,
  p_wallet      text,
  p_nonce       text,
  p_statement   text,
  p_ttl_seconds integer default 300
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_wallet is null or p_wallet !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$' then
    return jsonb_build_object('ok', false, 'code', 'bad-wallet',
      'message', 'That is not a base58 Solana address. No challenge was issued.');
  end if;

  -- A wallet already linked to somebody else is refused before a challenge is
  -- even issued, so the failure is a sentence rather than a signature the user
  -- made for nothing.
  if exists (
    select 1 from public.wallet_identities w
     where w.wallet = p_wallet and w.auth_user_id <> p_user_id
  ) then
    return jsonb_build_object('ok', false, 'code', 'wallet-linked',
      'message', 'That wallet is already linked to a different X account. No challenge was issued.');
  end if;

  -- Older open challenges for this session are burned. A user who started a link
  -- twice should not leave a spare valid nonce lying around behind them.
  update public.wallet_link_challenges
     set consumed_at = now()
   where auth_user_id = p_user_id and consumed_at is null;

  insert into public.wallet_link_challenges (nonce, wallet, auth_user_id, statement, expires_at)
  values (p_nonce, p_wallet, p_user_id, p_statement,
          now() + make_interval(secs => greatest(60, least(p_ttl_seconds, 900))));

  return jsonb_build_object('ok', true, 'nonce', p_nonce, 'statement', p_statement);
end;
$$;

-- The handle GoTrue recorded for this session, read from `auth.identities`.
--
-- Exists so that the statement a wallet is asked to sign names the SAME handle
-- the link will record. `link-wallet` could read the handle out of its own copy
-- of the session instead, and the two would agree almost always — "almost" being
-- the problem: a user who changed their X handle between signing in and linking
-- would sign a statement naming one handle and have another written down, and the
-- stored proof would no longer match the text it was made over.
create or replace function public.twitter_handle_for_user(p_user_id uuid)
returns text
language sql
security definer
stable
set search_path = ''
as $$
  select i.identity_data->>'user_name'
    from auth.identities i
   where i.user_id = p_user_id and i.provider = 'twitter'
   limit 1
$$;

-- The exact bytes that were issued, for a challenge that is still answerable.
--
-- Returns null for a challenge that does not exist, belongs to another session,
-- has expired, or has been spent — one answer for all four, because telling a
-- caller WHICH of those is telling them how far off they were.
--
-- Read-only. It does not consume the challenge; `complete_wallet_link` does that
-- in the same transaction as the write, which is what makes a replay impossible
-- rather than merely unlikely.
create or replace function public.wallet_link_challenge_statement(p_user_id uuid, p_nonce text)
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
  select jsonb_build_object('statement', c.statement, 'wallet', c.wallet, 'expires_at', c.expires_at)
    from public.wallet_link_challenges c
   where c.nonce = p_nonce
     and c.auth_user_id = p_user_id
     and c.consumed_at is null
     and c.expires_at > now()
$$;

-- Step two: record the link.
--
-- Called ONLY after `link-wallet` has verified the ed25519 signature against the
-- wallet's own public key. This function does not and cannot check the
-- cryptography — Postgres has no ed25519 primitive here — and pretending
-- otherwise would be worse than saying so. What it does guarantee, and what the
-- Edge Function cannot:
--
--   * the challenge existed, was issued to THIS user for THIS wallet, and has not
--     expired or been used;
--   * it is consumed in the same transaction as the link, so a replayed signature
--     finds it spent;
--   * the X handle is read from `auth.identities`, never from an argument;
--   * one wallet to one account in both directions, by unique constraints.
create or replace function public.complete_wallet_link(
  p_user_id   uuid,
  p_wallet    text,
  p_nonce     text,
  p_signature text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_challenge public.wallet_link_challenges;
  v_handle    text;
  v_provider  text;
begin
  select * into v_challenge
    from public.wallet_link_challenges
   where nonce = p_nonce
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'no-challenge',
      'message', 'That challenge does not exist. Nothing was linked.');
  end if;
  if v_challenge.consumed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'challenge-spent',
      'message', 'That challenge has already been used. Ask for a new one; nothing was linked.');
  end if;
  if v_challenge.expires_at <= now() then
    return jsonb_build_object('ok', false, 'code', 'challenge-expired',
      'message', 'That challenge expired. Ask for a new one; nothing was linked.');
  end if;
  -- The challenge names the user and the wallet. A signature is only proof of the
  -- pair it was issued for.
  if v_challenge.auth_user_id <> p_user_id or v_challenge.wallet <> p_wallet then
    return jsonb_build_object('ok', false, 'code', 'challenge-mismatch',
      'message', 'That challenge was issued for a different session or a different wallet. Nothing was linked.');
  end if;

  -- The X side, read from GoTrue's own record of the OAuth exchange. `user_name`
  -- is where the Twitter provider puts the handle; `sub` is the numeric account
  -- id, which is the stable half — a handle can be released and re-registered by
  -- somebody else, and a link keyed on it would follow it to the new owner.
  --
  -- Read out of `identity_data` rather than off the `provider_id` COLUMN, and the
  -- difference is availability rather than preference: `auth.identities.provider_id`
  -- was added to GoTrue partway through its life, so a query naming it fails at
  -- PARSE time on an older project — which would make this whole migration
  -- unpushable rather than making one link fail. `identity_data->>'sub'` has been
  -- populated by every version, and a jsonb key that is absent is a null this
  -- function already handles.
  select i.identity_data->>'user_name',
         coalesce(i.identity_data->>'sub', i.identity_data->>'provider_id')
    into v_handle, v_provider
    from auth.identities i
   where i.user_id = p_user_id and i.provider = 'twitter'
   limit 1;

  if v_handle is null or v_provider is null then
    return jsonb_build_object('ok', false, 'code', 'no-twitter-identity',
      'message', 'This session has no verified X identity, so there is no handle to link. Nothing was written.');
  end if;

  update public.wallet_link_challenges set consumed_at = now() where nonce = p_nonce;

  insert into public.wallet_identities
    (wallet, auth_user_id, twitter_user_id, twitter_handle, proof_nonce, proof_signature)
  values
    (p_wallet, p_user_id, v_provider, v_handle, p_nonce, p_signature)
  on conflict (wallet) do update
     set auth_user_id    = excluded.auth_user_id,
         twitter_user_id = excluded.twitter_user_id,
         twitter_handle  = excluded.twitter_handle,
         proof_nonce     = excluded.proof_nonce,
         proof_signature = excluded.proof_signature,
         linked_at       = now();

  insert into public.profiles (wallet, twitter_user_id, twitter_handle, twitter_verified_at, auth_user_id)
  values (p_wallet, v_provider, v_handle, now(), p_user_id)
  on conflict (wallet) do update
     set twitter_user_id     = excluded.twitter_user_id,
         twitter_handle      = excluded.twitter_handle,
         twitter_verified_at = excluded.twitter_verified_at,
         auth_user_id        = excluded.auth_user_id,
         updated_at          = now();

  -- The mirror. Its trigger re-reads public.profiles, so this only succeeds
  -- because the row above was written first — the guard is checking the write
  -- that just happened rather than the argument that asked for it.
  insert into public.wallets (address, twitter) values (p_wallet, v_handle)
  on conflict (address) do update set twitter = excluded.twitter;

  return jsonb_build_object('ok', true, 'wallet', p_wallet, 'twitter_handle', v_handle);
end;
$$;

-- Unlinking. Drops the proof and the verified columns together — a profile
-- keeping a handle whose proof has been withdrawn is exactly the unverified claim
-- this file exists to make unrepresentable.
create or replace function public.unlink_wallet(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  delete from public.wallet_identities where auth_user_id = p_user_id;

  update public.profiles
     set twitter_user_id = null, twitter_handle = null, twitter_verified_at = null,
         auth_user_id = null, updated_at = now()
   where wallet = v_wallet;

  update public.wallets set twitter = null where address = v_wallet;

  return jsonb_build_object('ok', true, 'wallet', v_wallet);
end;
$$;

-- Housekeeping for the nonce table. Nothing depends on it having run — an expired
-- challenge is refused by `complete_wallet_link` whether or not it has been swept
-- — so this is disk hygiene rather than a security control, and it is written to
-- say so.
create or replace function public.purge_wallet_link_challenges()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gone integer;
begin
  delete from public.wallet_link_challenges
   where expires_at < now() - interval '7 days';
  get diagnostics v_gone = row_count;
  return v_gone;
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.actor_wallet(uuid) from public, anon, authenticated;
revoke all on function public.set_profile(uuid, text, text, bigint) from public, anon, authenticated;
revoke all on function public.issue_wallet_link_challenge(uuid, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.complete_wallet_link(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.unlink_wallet(uuid) from public, anon, authenticated;
revoke all on function public.purge_wallet_link_challenges() from public, anon, authenticated;
revoke all on function public.twitter_handle_for_user(uuid) from public, anon, authenticated;
revoke all on function public.wallet_link_challenge_statement(uuid, text) from public, anon, authenticated;
-- `guard_wallet_twitter` is deliberately NOT revoked, for the reason given in
-- 20260806090600 about `stamp_xployee_identity`: it is a trigger function with no
-- argument list to invoke, and revoking EXECUTE from PUBLIC on one is a known way
-- to turn an ordinary write into "permission denied for function".

grant execute on function public.twitter_handle_for_user(uuid) to service_role;
grant execute on function public.wallet_link_challenge_statement(uuid, text) to service_role;
grant execute on function public.actor_wallet(uuid) to service_role;
grant execute on function public.set_profile(uuid, text, text, bigint) to service_role;
grant execute on function public.issue_wallet_link_challenge(uuid, text, text, text, integer) to service_role;
grant execute on function public.complete_wallet_link(uuid, text, text, text) to service_role;
grant execute on function public.unlink_wallet(uuid) to service_role;
grant execute on function public.purge_wallet_link_challenges() to service_role;


-- =========================================================================
-- SECTION 13 of 18 — 20260806090800_market_and_epochs.sql
-- =========================================================================

-- xNFTs index — the simulated marketplace and the epoch ledger.
--
-- ===========================================================================
-- EVERYTHING IN THIS FILE IS SIMULATED, AND IT IS STILL ENFORCED
-- ===========================================================================
-- Sales and rentals move no tokens. There is no escrow program, so an atomic
-- swap would need both parties to co-sign one transaction and nothing arranges
-- that — a sale is a row in `public.trades` and a rental is a row in
-- `public.rentals`, exactly as 20260805120000 says.
--
-- Simulated does NOT mean unchecked, and the distinction is the whole point of
-- this migration. A simulated ledger has no chain reading to contradict it, so a
-- wrong row here is wrong forever and there is nothing to reconcile it against.
-- That makes the invariants MORE important than on the chain-backed tables, not
-- less:
--
--   * a seller must own what they list, at the moment they list it;
--   * a buyer cannot buy their own listing, and cannot buy one that has already
--     closed — checked under a row lock, so two simultaneous buyers cannot both
--     win;
--   * ownership moves in the same transaction as the trade row, so a sale that
--     records money without moving the asset is unreachable;
--   * a rented xployee cannot be re-rented until its contract ends.
--
-- ===========================================================================
-- THE FEE LEDGERS ARE SEPARATE, DELIBERATELY
-- ===========================================================================
-- `public.fee_ledger` is reconciled against a treasury token account anyone can
-- read on chain, and 20260806090000 narrowed it further so that only rentals
-- with a real transfer behind them can enter it. A simulated marketplace fee has
-- no deposit behind it, so it goes to `public.sim_fee_ledger` instead. Two
-- tables rather than one table with a flag, because the flag is exactly the
-- thing a `sum(amount)` written in a hurry forgets — and the resulting number
-- would be a treasury balance overstated by every sale the theatre ever staged.
--
-- ===========================================================================
-- WHO IS ACTING
-- ===========================================================================
-- Every writer takes an `auth.users` id and resolves the wallet through
-- `public.actor_wallet`. None of them takes a wallet address, so there is no
-- writer that can be pointed at somebody else's holdings.

-- ---------------------------------------------------------------------------
-- Rates
-- ---------------------------------------------------------------------------

-- Mirrors SIM_SALE_FEE_BPS and SIM_RENT_FEE_BPS in src/lib/fees.ts. Named SIM_
-- there and `sim_` here for the same reason: the mint has no fee at all, and a
-- constant that merely reads as "the protocol fee" is how a retired charge gets
-- threaded back into the one action that is real.
--
-- Floor division, matching `feeOn()` exactly: both operands are non-negative, so
-- truncation toward zero IS floor, and the payer is never overcharged by a unit.
create or replace function public.sim_sale_fee_bps() returns integer
language sql immutable parallel safe set search_path = '' as $$ select 500 $$;

create or replace function public.sim_rent_fee_bps() returns integer
language sql immutable parallel safe set search_path = '' as $$ select 1000 $$;

create or replace function public.sim_fee_on(p_gross numeric, p_bps integer)
returns numeric
language sql
immutable
parallel safe
strict
set search_path = ''
as $$ select trunc(p_gross * p_bps / 10000) $$;

comment on function public.sim_fee_on(numeric, integer) is
  'The simulated marketplace fee on a gross amount in raw units, floored. Matches feeOn() in src/lib/fees.ts — same division, same direction, so a quote on screen and the row written here cannot disagree about a rounding unit.';

-- ---------------------------------------------------------------------------
-- listings — the write path 20260805120000 said did not exist yet
-- ---------------------------------------------------------------------------

alter table public.listings
  -- The rate in force when the listing was made. Snapshotted rather than read at
  -- settlement, so changing the marketplace rate cannot silently reprice an
  -- advertisement somebody is already looking at.
  add column if not exists fee_bps integer,
  add column if not exists cancelled_at timestamptz,
  add column if not exists closed_by public.base58_address;

alter table public.listings
  add constraint listings_fee_bps_sane check (fee_bps is null or (fee_bps >= 0 and fee_bps <= 2000));

comment on column public.listings.nft_mint is
  'The xployee''s art_seed — what src/lib/xployee.ts calls `Xployee.mint` and src/lib/market.ts keys a listing by. A deterministic pseudo-address, NOT a token mint: there is no NFT on Solana, and nothing may derive an account from this.';
comment on column public.listings.fee_bps is
  'The simulated fee rate this listing was made under. Snapshotted so a rate change cannot reprice a live advertisement.';

create index if not exists listings_active_idx on public.listings (kind, updated_at desc) where status = 'active';

-- ---------------------------------------------------------------------------
-- rentals — the table the chain could not fill
-- ---------------------------------------------------------------------------

-- 20260805120000 declined to create this, and its reasoning was right for the
-- case it was about: a chain-verified rental is two token transfers, and two
-- transfers cannot say for how many epochs, so a `rentals` table written from
-- ingestion would need a `term_epochs` column nothing could fill.
--
-- A SIMULATED rental is a different object. The term is not recovered from
-- anywhere — it is stated by the contract the renter accepted, which is a row in
-- `public.listings` this database wrote itself. There is nothing to reconstruct
-- and nothing to guess.
--
-- The chain-backed path is unchanged: `record_rent` still writes a fee row and
-- still declines to invent a term. If a rental is ever settled on chain it lands
-- in `fee_ledger` with `origin = 'chain'`, and these rows stay what they say they
-- are.
create table public.rentals (
  id           uuid primary key default gen_random_uuid(),
  xployee_id   bigint not null references public.xployees (id) on delete restrict,
  owner        public.base58_address not null,
  renter       public.base58_address not null,

  -- Money in raw units as digit strings, for the reason the u64_text domain
  -- exists: PostgREST serialises numeric as a JSON number and a raw u64 loses its
  -- low digits on the way to a browser.
  fee_per_epoch public.u64_text not null,
  term_epochs   integer not null check (term_epochs > 0 and term_epochs <= 365),
  gross         public.u64_text not null,
  fee           public.u64_text not null,
  total         public.u64_text not null,
  fee_bps       integer not null check (fee_bps >= 0 and fee_bps <= 2000),

  -- Protocol epochs, from public.protocol_epoch(). Half-open: the contract covers
  -- [start_epoch, end_epoch).
  start_epoch integer not null check (start_epoch >= 0),
  end_epoch   integer not null check (end_epoch > start_epoch),

  status text not null default 'active' check (status in ('active', 'completed', 'cancelled')),
  origin public.row_origin not null default 'simulated',

  created_at   timestamptz not null default now(),
  ended_at     timestamptz,

  constraint rentals_term_matches_epochs check (end_epoch - start_epoch = term_epochs),
  -- The renter is not the owner. A self-rental would move no value and would
  -- redirect the epoch yield to the wallet that was already receiving it.
  constraint rentals_parties_differ check (renter <> owner),
  constraint rentals_settled_has_timestamp check (
    (status = 'active' and ended_at is null) or (status <> 'active' and ended_at is not null)
  ),
  -- Simulated rows carry no signature, and a row claiming 'chain' would have to
  -- have come from somewhere this writer cannot reach.
  constraint rentals_are_simulated check (origin = 'simulated')
);

-- One live contract per xployee. A constraint, not a check the writer performs:
-- two renters holding one worker would both be credited its epoch yield, and the
-- ledger would pay out twice for one desk.
create unique index rentals_one_active_per_xployee
  on public.rentals (xployee_id) where status = 'active';

create index rentals_renter_idx on public.rentals (renter, created_at desc);
create index rentals_owner_idx  on public.rentals (owner, created_at desc);
create index rentals_window_idx on public.rentals (start_epoch, end_epoch) where status = 'active';

comment on table public.rentals is
  'SIMULATED rental contracts. The xployee never moves; what moves is who is credited its epoch yield for the term. The term is stated by the listing this database wrote, not recovered from a transaction — which is why this table can exist for simulated rentals and could not for chain-verified ones.';

-- ---------------------------------------------------------------------------
-- sim_fee_ledger — the theatre's own revenue line
-- ---------------------------------------------------------------------------

create table public.sim_fee_ledger (
  id        uuid primary key default gen_random_uuid(),
  source    text not null check (source in ('sale', 'rent')),
  -- What the fee was charged against, so a row can be traced to the thing that
  -- produced it. Exactly one is set.
  trade_id  uuid references public.trades (id) on delete cascade,
  rental_id uuid references public.rentals (id) on delete cascade,
  payer     public.base58_address not null,
  amount    public.u64_text not null,
  fee_bps   integer not null check (fee_bps >= 0 and fee_bps <= 2000),
  origin    public.row_origin not null default 'simulated' check (origin = 'simulated'),
  charged_at timestamptz not null default now(),
  constraint sim_fee_ledger_has_one_source check (
    (source = 'sale' and trade_id is not null and rental_id is null)
    or (source = 'rent' and rental_id is not null and trade_id is null)
  )
);

create index sim_fee_ledger_charged_idx on public.sim_fee_ledger (charged_at desc);
create index sim_fee_ledger_source_idx  on public.sim_fee_ledger (source, charged_at desc);

comment on table public.sim_fee_ledger is
  'SIMULATED marketplace fees. Never summed with public.fee_ledger: that one is reconciled against a treasury token account, and every row here describes money that did not move. Two tables rather than one with a flag, because the flag is what a hurried sum() forgets.';

-- ---------------------------------------------------------------------------
-- Epochs
-- ---------------------------------------------------------------------------

-- Genesis and epoch length, matching src/lib/accrual.ts: GENESIS is
-- Date.UTC(2026, 0, 6) and an epoch is 24 hours. Fixed so epoch numbering is the
-- same on every machine and in the database.
create or replace function public.protocol_genesis()
returns timestamptz
language sql immutable parallel safe set search_path = ''
as $$ select timestamptz '2026-01-06 00:00:00+00' $$;

create or replace function public.protocol_epoch(p_at timestamptz default now())
returns integer
language sql
stable
parallel safe
set search_path = ''
as $$
  select greatest(0, floor(extract(epoch from (p_at - public.protocol_genesis())) / 86400))::integer
$$;

create or replace function public.epoch_start(p_epoch integer)
returns timestamptz
language sql immutable parallel safe strict set search_path = ''
as $$ select public.protocol_genesis() + make_interval(days => p_epoch) $$;

comment on function public.protocol_epoch(timestamptz) is
  'The protocol epoch containing a timestamp. Mirrors epochAt() in src/lib/accrual.ts: 24-hour epochs from 2026-01-06T00:00:00Z, floored at 0.';

-- Per-epoch aggregates. Written by settle_epoch, one row per epoch, never
-- rewritten: a settled epoch is history, and history that can be recomputed under
-- you is not a ledger.
create table public.epochs (
  epoch      integer primary key check (epoch >= 0),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  -- How many workers were on the books when this epoch settled.
  workers            integer not null default 0 check (workers >= 0),
  principal_usd      numeric(20, 2) not null default 0 check (principal_usd >= 0),
  yield_usd          numeric(20, 6) not null default 0 check (yield_usd >= 0),
  settled_at timestamptz not null default now(),
  constraint epochs_span check (ends_at = starts_at + interval '1 day')
);

comment on table public.epochs is
  'One row per settled epoch. Append-only: settle_epoch refuses to rewrite an epoch it has already closed, because a book value that can be recomputed retroactively is not a book value.';

-- The per-worker line items behind each epoch row.
--
-- `credited_to` is the renter while a contract is live and the owner otherwise —
-- that redirection IS what renting an xployee buys, and recording it per epoch is
-- what makes a contract auditable after it ends. The owner is kept alongside so a
-- reader can see the redirection rather than infer it.
create table public.epoch_yields (
  epoch       integer not null references public.epochs (epoch) on delete cascade,
  xployee_id  bigint  not null references public.xployees (id) on delete cascade,
  owner       public.base58_address not null,
  credited_to public.base58_address not null,
  rental_id   uuid references public.rentals (id) on delete set null,
  yield_usd   numeric(20, 6) not null check (yield_usd >= 0),
  primary key (epoch, xployee_id)
);

create index epoch_yields_credited_idx on public.epoch_yields (credited_to, epoch desc);
create index epoch_yields_owner_idx on public.epoch_yields (owner, epoch desc);

comment on table public.epoch_yields is
  'Per-worker, per-epoch accrual. credited_to is the renter during a live contract and the owner otherwise — the redirection is the whole product of a rental, so it is recorded rather than derived later from a contract that may have ended.';

-- ---------------------------------------------------------------------------
-- settle_epoch
-- ---------------------------------------------------------------------------

-- Closes one epoch. Idempotent by the primary key on public.epochs: re-running it
-- returns 'already-settled' and changes nothing, so a cron that fires twice, or a
-- backfill overlapping a live schedule, cannot double-credit a wallet.
--
-- Refuses to settle an epoch that has not finished. A partial epoch settled early
-- would be a full epoch's credit for part of one, and the correction would have
-- to rewrite a row this table does not allow to be rewritten.
--
-- Yield is `principal x apy / 365`, matching yieldPerEpoch() in src/lib/accrual.ts,
-- in exact decimal arithmetic. No float touches it.
create or replace function public.settle_epoch(p_epoch integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_rows  integer;
begin
  if p_epoch is null or p_epoch < 0 then
    return jsonb_build_object('ok', false, 'code', 'bad-epoch', 'message', 'Epochs start at 0.');
  end if;

  v_start := public.epoch_start(p_epoch);
  if v_start + interval '1 day' > now() then
    return jsonb_build_object(
      'ok', false, 'code', 'epoch-open',
      'message', format('Epoch %s has not finished. Nothing was settled.', p_epoch)
    );
  end if;

  if exists (select 1 from public.epochs where epoch = p_epoch) then
    return jsonb_build_object('ok', true, 'outcome', 'already-settled', 'epoch', p_epoch);
  end if;

  insert into public.epochs (epoch, starts_at, ends_at)
  values (p_epoch, v_start, v_start + interval '1 day');

  -- Only workers that were already hired when the epoch STARTED accrue for it. A
  -- worker hired midway through would otherwise be credited a full epoch for a
  -- few hours, which is the one direction this ledger must not err in.
  insert into public.epoch_yields (epoch, xployee_id, owner, credited_to, rental_id, yield_usd)
  select
    p_epoch,
    x.id,
    x.owner,
    coalesce(r.renter, x.owner),
    r.id,
    round(x.principal * x.apy / 365, 6)
  from public.xployees x
  left join public.rentals r
    on r.xployee_id = x.id
   and r.status = 'active'
   and p_epoch >= r.start_epoch
   and p_epoch <  r.end_epoch
  where x.owner is not null
    and x.hired_at is not null
    and x.hired_at <= v_start;

  get diagnostics v_rows = row_count;

  update public.epochs e
     set workers       = agg.workers,
         principal_usd = agg.principal,
         yield_usd     = agg.yield
    from (
      select count(*)                as workers,
             coalesce(sum(x.principal), 0) as principal,
             coalesce(sum(y.yield_usd), 0) as yield
        from public.epoch_yields y
        join public.xployees x on x.id = y.xployee_id
       where y.epoch = p_epoch
    ) agg
   where e.epoch = p_epoch;

  -- Contracts that ran out during this epoch are closed here rather than by a
  -- separate sweep, so "the term ended" and "the yield stopped being redirected"
  -- are the same event.
  update public.rentals
     set status = 'completed', ended_at = now()
   where status = 'active' and end_epoch <= p_epoch + 1;

  return jsonb_build_object('ok', true, 'outcome', 'settled', 'epoch', p_epoch, 'workers', v_rows);
end;
$$;

-- Settles every finished epoch that has not been closed yet, oldest first, up to
-- a bound. The bound exists because a project that has been idle for a month
-- would otherwise try to settle thirty epochs x five thousand workers in one
-- statement timeout.
create or replace function public.settle_due_epochs(p_max integer default 7)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current integer := public.protocol_epoch();
  v_done    integer := 0;
  v_epoch   integer;
  v_last    integer;
begin
  select coalesce(max(epoch), -1) into v_last from public.epochs;
  v_epoch := v_last + 1;

  while v_epoch < v_current and v_done < greatest(1, least(p_max, 60)) loop
    perform public.settle_epoch(v_epoch);
    v_done  := v_done + 1;
    v_epoch := v_epoch + 1;
  end loop;

  return jsonb_build_object('ok', true, 'settled', v_done, 'through_epoch', v_epoch - 1, 'current_epoch', v_current);
end;
$$;

-- ---------------------------------------------------------------------------
-- record_simulated_sale — repaired
-- ---------------------------------------------------------------------------

-- 20260805120100 defined this with an UPSERT on public.xployees, so a sale of a
-- serial the index had never seen created it, owned by the buyer. That was the
-- right call when the index was a sparse read model that might not have heard of
-- an xployee yet.
--
-- It is the wrong call now, and the seed is why: all 5,000 exist from
-- 20260806090300, so an id the upsert does not find is not a gap to fill — it is
-- an id outside the collection, and creating it would mint a 5,001st xployee
-- through the sales endpoint. `xployees_within_supply` would refuse the insert,
-- but as an exception from a constraint rather than as a sentence about a sale.
--
-- Two things change. The upsert becomes an UPDATE that raises when it matches
-- nothing, and the seller has to actually own the thing they are selling —
-- because a simulated sale has no chain reading to contradict it, so "seller"
-- being unchecked meant any caller could move any xployee to anyone.
create or replace function public.record_simulated_sale(
  p_sale_ref      text,
  p_xployee_id    bigint,
  p_nft_mint      text,
  p_buyer         text,
  p_seller        text,
  p_gross         text,
  p_fee           text,
  p_net_to_seller text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
  v_owner    text;
  v_trade    uuid;
begin
  if p_buyer = p_seller then
    raise exception 'record_simulated_sale: buyer and seller are the same wallet';
  end if;

  -- The row is locked before it is checked, so a second concurrent sale of the
  -- same xployee waits here and then finds the owner has changed.
  select owner into v_owner from public.xployees where id = p_xployee_id for update;
  if not found then
    raise exception 'record_simulated_sale: xployee % is not in the collection', p_xployee_id;
  end if;
  if v_owner is null or v_owner <> p_seller then
    raise exception 'record_simulated_sale: % does not own xployee %', p_seller, p_xployee_id;
  end if;

  insert into public.trades (sale_ref, xployee_id, nft_mint, buyer, seller, gross, fee, net_to_seller, origin)
  values (p_sale_ref, p_xployee_id, p_nft_mint, p_buyer, p_seller, p_gross, p_fee, p_net_to_seller, 'simulated')
  on conflict (sale_ref) do nothing
  returning id into v_trade;
  v_inserted := found;

  -- Only on a first sighting. Replaying a sale must not move ownership again,
  -- because by then a later sale may have moved it on.
  if v_inserted then
    update public.xployees set owner = p_buyer, updated_at = now() where id = p_xployee_id;

    update public.listings l
       set status = 'sold', updated_at = now(), closed_by = p_buyer
     where l.xployee_id = p_xployee_id and l.status = 'active';

    -- The fee is notional and goes to the SIMULATED ledger. It has never entered
    -- public.fee_ledger and 20260806090000 now makes that structural rather than
    -- conventional.
    if p_fee is not null and p_fee <> '0' then
      insert into public.sim_fee_ledger (source, trade_id, payer, amount, fee_bps)
      values ('sale', v_trade, p_buyer, p_fee, public.sim_sale_fee_bps());
    end if;
  end if;

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Listing writers
-- ---------------------------------------------------------------------------

create or replace function public.create_listing(
  p_user_id       uuid,
  p_xployee_id    bigint,
  p_kind          text,
  p_price         text default null,
  p_fee_per_epoch text default null,
  p_term_epochs   integer default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
  v_mint   text;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was listed.');
  end if;
  if p_kind not in ('sale', 'rent') then
    return jsonb_build_object('ok', false, 'code', 'bad-kind',
      'message', 'A listing is a sale or a rent. Nothing was listed.');
  end if;

  -- Read, not `for update`. `buy_listing` locks the listing and then the xployee;
  -- taking them in the other order here would be a deadlock waiting for two
  -- unlucky requests. Listing is an advertisement — a race between listing and
  -- selling the same worker resolves at the sale, where the lock that matters is.
  select x.art_seed into v_mint
    from public.xployees x
   where x.id = p_xployee_id and x.owner = v_wallet;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not-owned',
      'message', 'This wallet does not own that xployee. Nothing was listed.');
  end if;

  if exists (select 1 from public.listings where xployee_id = p_xployee_id and status = 'active') then
    return jsonb_build_object('ok', false, 'code', 'already-listed',
      'message', 'That xployee is already on the market. Cancel the existing listing first.');
  end if;
  -- A worker under contract is not the seller's to hand over: the renter is
  -- collecting its yield until the term ends.
  if exists (select 1 from public.rentals where xployee_id = p_xployee_id and status = 'active') then
    return jsonb_build_object('ok', false, 'code', 'under-contract',
      'message', 'That xployee is out on a rental contract. It can be listed when the term ends.');
  end if;

  -- The listings table's own listings_priced_by_kind constraint would refuse a
  -- sale with no price, but as an exception rather than as an explanation.
  if p_kind = 'sale' and (p_price is null or p_price !~ '^(0|[1-9][0-9]{0,19})$' or p_price = '0') then
    return jsonb_build_object('ok', false, 'code', 'bad-price',
      'message', 'A sale listing needs a price in raw units, as a decimal string above zero. Nothing was listed.');
  end if;
  if p_kind = 'rent' and (
       p_fee_per_epoch is null or p_fee_per_epoch !~ '^(0|[1-9][0-9]{0,19})$' or p_fee_per_epoch = '0'
       or p_term_epochs is null or p_term_epochs <= 0 or p_term_epochs > 365) then
    return jsonb_build_object('ok', false, 'code', 'bad-terms',
      'message', 'A rent listing needs a per-epoch fee in raw units and a term of 1–365 epochs. Nothing was listed.');
  end if;

  -- The old row for this xployee is replaced rather than accumulated: nft_mint is
  -- the primary key and a previous cancelled listing would collide with it. The
  -- history of a listing is the trade or rental it produced, not a pile of
  -- closed advertisements.
  delete from public.listings where xployee_id = p_xployee_id;

  insert into public.listings (
    nft_mint, xployee_id, seller, kind, price, fee_per_epoch, term_epochs, status, fee_bps
  ) values (
    v_mint, p_xployee_id, v_wallet, p_kind,
    case when p_kind = 'sale' then p_price end,
    case when p_kind = 'rent' then p_fee_per_epoch end,
    case when p_kind = 'rent' then p_term_epochs end,
    'active',
    case when p_kind = 'sale' then public.sim_sale_fee_bps() else public.sim_rent_fee_bps() end
  );

  return jsonb_build_object('ok', true, 'xployee_id', p_xployee_id, 'kind', p_kind, 'nft_mint', v_mint);
end;
$$;

create or replace function public.cancel_listing(p_user_id uuid, p_xployee_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
  v_hit    integer;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  update public.listings
     set status = 'cancelled', cancelled_at = now(), updated_at = now(), closed_by = v_wallet
   where xployee_id = p_xployee_id and seller = v_wallet and status = 'active';
  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'code', 'not-found',
      'message', 'This wallet has no active listing for that xployee. Nothing was changed.');
  end if;
  return jsonb_build_object('ok', true, 'xployee_id', p_xployee_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- buy_listing — the simulated sale, end to end
-- ---------------------------------------------------------------------------

-- The listing row is taken `for update` before anything is decided, so two buyers
-- arriving together serialise: the first closes it, the second finds it closed
-- and is told so. Nothing about that depends on the order PostgREST happened to
-- process the two requests in.
--
-- The price is read off the LISTING, never from the caller. A buyer who could
-- send their own price would be writing the seller's proceeds.
create or replace function public.buy_listing(p_user_id uuid, p_xployee_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_buyer  text;
  v_listing public.listings;
  v_gross  numeric;
  v_fee    numeric;
  v_net    numeric;
  v_ref    text;
begin
  v_buyer := public.actor_wallet(p_user_id);
  if v_buyer is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was bought.');
  end if;

  select * into v_listing
    from public.listings
   where xployee_id = p_xployee_id and kind = 'sale'
   for update;

  if not found or v_listing.status <> 'active' then
    return jsonb_build_object('ok', false, 'code', 'not-listed',
      'message', 'That xployee is not for sale. Nothing was bought.');
  end if;
  if v_listing.seller = v_buyer then
    return jsonb_build_object('ok', false, 'code', 'own-listing',
      'message', 'That is this wallet''s own listing. Nothing was bought.');
  end if;

  -- The seller must still own it.
  --
  -- `record_simulated_sale` checks this too and RAISES if it fails, which is the
  -- right behaviour for a low-level writer and the wrong response for a buyer: an
  -- exception escapes as a 500 with a Postgres string in it, and "the seller sold
  -- it to somebody else a second ago" is an ordinary outcome that deserves a
  -- sentence. Checked here so the common case reads properly; the raise below
  -- stays as the last line of defence, because this check and the ownership
  -- update are not in the same statement.
  if not exists (
    select 1 from public.xployees x where x.id = p_xployee_id and x.owner = v_listing.seller
  ) then
    return jsonb_build_object('ok', false, 'code', 'stale-listing',
      'message', 'That listing was posted by a wallet that no longer owns the xployee. Nothing was bought.');
  end if;

  v_gross := v_listing.price::numeric;
  v_fee   := public.sim_fee_on(v_gross, coalesce(v_listing.fee_bps, public.sim_sale_fee_bps()));
  -- The fee rides ON TOP of the ask, exactly as saleMath() in src/lib/market.ts
  -- quotes it: the seller receives the ask and the buyer is debited ask + fee. So
  -- the seller's net IS the gross, and `net_to_seller` records that rather than
  -- silently deducting a fee the quote never showed.
  v_net   := v_gross;

  -- A deterministic idempotency key. `record_simulated_sale` keys replay
  -- protection on `sale_ref`, and a uuid generated here would make every retry a
  -- second sale; keyed on the listing and the buyer, a retry lands on the row the
  -- first attempt wrote.
  v_ref := 'sale:' || p_xployee_id::text || ':' || v_listing.updated_at::text || ':' || v_buyer;

  perform public.record_simulated_sale(
    v_ref,
    p_xployee_id,
    v_listing.nft_mint,
    v_buyer,
    v_listing.seller,
    trunc(v_gross)::text,
    trunc(v_fee)::text,
    trunc(v_net)::text
  );

  return jsonb_build_object(
    'ok', true,
    'xployee_id', p_xployee_id,
    'seller', v_listing.seller,
    'gross', trunc(v_gross)::text,
    'fee', trunc(v_fee)::text,
    'total', trunc(v_gross + v_fee)::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- rent_listing — the simulated contract
-- ---------------------------------------------------------------------------

create or replace function public.rent_listing(p_user_id uuid, p_xployee_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_renter  text;
  v_listing public.listings;
  v_gross   numeric;
  v_fee     numeric;
  v_start   integer := public.protocol_epoch();
  v_rental  uuid;
begin
  v_renter := public.actor_wallet(p_user_id);
  if v_renter is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was rented.');
  end if;

  select * into v_listing
    from public.listings
   where xployee_id = p_xployee_id and kind = 'rent'
   for update;

  if not found or v_listing.status <> 'active' then
    return jsonb_build_object('ok', false, 'code', 'not-listed',
      'message', 'That xployee is not offered on contract. Nothing was rented.');
  end if;
  if v_listing.seller = v_renter then
    return jsonb_build_object('ok', false, 'code', 'own-listing',
      'message', 'That is this wallet''s own contract. Nothing was rented.');
  end if;
  -- The listing's seller must still be the owner. A stale advertisement left
  -- behind by a previous owner would otherwise let a renter pay the wrong wallet.
  if not exists (
    select 1 from public.xployees x where x.id = p_xployee_id and x.owner = v_listing.seller
  ) then
    return jsonb_build_object('ok', false, 'code', 'stale-listing',
      'message', 'That contract was posted by a wallet that no longer owns the xployee. Nothing was rented.');
  end if;

  v_gross := v_listing.fee_per_epoch::numeric * v_listing.term_epochs;
  v_fee   := public.sim_fee_on(v_gross, coalesce(v_listing.fee_bps, public.sim_rent_fee_bps()));

  insert into public.rentals (
    xployee_id, owner, renter, fee_per_epoch, term_epochs,
    gross, fee, total, fee_bps, start_epoch, end_epoch
  ) values (
    p_xployee_id, v_listing.seller, v_renter, v_listing.fee_per_epoch, v_listing.term_epochs,
    trunc(v_gross)::text, trunc(v_fee)::text, trunc(v_gross + v_fee)::text,
    coalesce(v_listing.fee_bps, public.sim_rent_fee_bps()),
    v_start, v_start + v_listing.term_epochs
  )
  returning id into v_rental;

  insert into public.sim_fee_ledger (source, rental_id, payer, amount, fee_bps)
  values ('rent', v_rental, v_renter, trunc(v_fee)::text, coalesce(v_listing.fee_bps, public.sim_rent_fee_bps()));

  update public.listings
     set status = 'rented', updated_at = now(), closed_by = v_renter
   where xployee_id = p_xployee_id;

  return jsonb_build_object(
    'ok', true,
    'rental_id', v_rental,
    'xployee_id', p_xployee_id,
    'owner', v_listing.seller,
    'term_epochs', v_listing.term_epochs,
    'start_epoch', v_start,
    'end_epoch', v_start + v_listing.term_epochs,
    'gross', trunc(v_gross)::text,
    'fee', trunc(v_fee)::text,
    'total', trunc(v_gross + v_fee)::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.settle_epoch(integer) from public, anon, authenticated;
revoke all on function public.settle_due_epochs(integer) from public, anon, authenticated;
revoke all on function public.create_listing(uuid, bigint, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.cancel_listing(uuid, bigint) from public, anon, authenticated;
revoke all on function public.buy_listing(uuid, bigint) from public, anon, authenticated;
revoke all on function public.rent_listing(uuid, bigint) from public, anon, authenticated;
revoke all on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) from public, anon, authenticated;

grant execute on function public.settle_epoch(integer) to service_role;
grant execute on function public.settle_due_epochs(integer) to service_role;
grant execute on function public.create_listing(uuid, bigint, text, text, text, integer) to service_role;
grant execute on function public.cancel_listing(uuid, bigint) to service_role;
grant execute on function public.buy_listing(uuid, bigint) to service_role;
grant execute on function public.rent_listing(uuid, bigint) to service_role;
grant execute on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) to service_role;

-- Pure, read-only, and called by generated columns and by the app alike.
grant execute on function public.protocol_genesis() to public;
grant execute on function public.protocol_epoch(timestamptz) to public;
grant execute on function public.epoch_start(integer) to public;
grant execute on function public.sim_sale_fee_bps() to public;
grant execute on function public.sim_rent_fee_bps() to public;
grant execute on function public.sim_fee_on(numeric, integer) to public;


-- =========================================================================
-- SECTION 14 of 18 — 20260806090900_social.sql
-- =========================================================================

-- xNFTs index — the social layer: friends, threads, messages, trade offers.
--
-- ===========================================================================
-- WHAT THIS REPLACES
-- ===========================================================================
-- `src/lib/social.ts` keeps the whole inbox in one localStorage blob per wallet,
-- with the other half of every conversation simulated from network.ts. That was
-- the right shape for a frontend with no backend, and it has one property this
-- schema has to preserve and one it has to fix.
--
--   Preserve: nothing here throws at the reader. A corrupt row, a missing
--             counterparty, a message from a wallet that no longer exists — all
--             of it degrades to a shorter list, never to a blank page.
--   Fix:      a conversation is between two people. A store only one of them can
--             write is not a conversation, it is a diary. Every table below is
--             two-sided and symmetric by construction.
--
-- ===========================================================================
-- SYMMETRY IS STRUCTURAL, NOT MAINTAINED
-- ===========================================================================
-- `friendships` and `threads` both key on an ORDERED PAIR — `wallet_a < wallet_b`
-- as a check constraint — so there is exactly one row per relationship and A
-- lists B precisely when B lists A. The alternative, two mirrored rows kept in
-- step by a writer, is a pair that drifts the first time one insert fails: one
-- wallet sees a friend, the other sees a stranger, and nothing ever notices.
--
-- `src/lib/social.ts` reaches the same property a different way, by seeding its
-- pair roll on the unordered pair. Same reasoning, and it is worth being explicit
-- that the one-way friendship is a bug both designs were built to make
-- unrepresentable rather than unlikely.
--
-- ===========================================================================
-- A TRADE OFFER MOVES NOTHING
-- ===========================================================================
-- Accepting one records a decision. There is no custody here and no escrow
-- anywhere in this protocol, so an accepted offer does NOT reassign an xployee —
-- and `accept_trade_offer` deliberately does not touch `public.xployees`. Making
-- it move assets would be inventing a settlement layer inside a messaging table,
-- with none of the ownership checks `buy_listing` performs and no way to make the
-- two legs atomic against a counterparty who sold in the meantime.
--
-- The offer legs still name real xployees and are still validated against real
-- ownership at send time, because an offer for units the sender does not hold is
-- a lie whether or not anything settles it.

-- ---------------------------------------------------------------------------
-- friend_requests
-- ---------------------------------------------------------------------------

create table public.friend_requests (
  id           uuid primary key default gen_random_uuid(),
  requester    public.base58_address not null,
  addressee    public.base58_address not null,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  message      text check (message is null or length(message) <= 200),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  constraint friend_requests_two_parties check (requester <> addressee),
  constraint friend_requests_resolved_has_timestamp check (
    (status = 'pending' and responded_at is null) or (status <> 'pending' and responded_at is not null)
  )
);

-- At most one OPEN request per unordered pair, in either direction. `least` and
-- `greatest` collapse the direction, so B cannot answer A's pending request by
-- sending their own and ending up with two rows that disagree about who asked.
create unique index friend_requests_one_open_per_pair
  on public.friend_requests (least(requester, addressee), greatest(requester, addressee))
  where status = 'pending';

create index friend_requests_inbox_idx  on public.friend_requests (addressee, status, created_at desc);
create index friend_requests_outbox_idx on public.friend_requests (requester, status, created_at desc);

comment on table public.friend_requests is
  'Both directions and every status — the audit trail behind public.friendships. A resolved request is history and stays; only pending rows are inbox items.';

-- ---------------------------------------------------------------------------
-- friendships
-- ---------------------------------------------------------------------------

create table public.friendships (
  -- Canonically ordered, so the pair is the key and the relationship has exactly
  -- one row. This is what makes the graph undirected at the storage layer instead
  -- of by convention.
  wallet_a   public.base58_address not null,
  wallet_b   public.base58_address not null,
  since      timestamptz not null default now(),
  -- The request that produced it, when there was one. Null for a friendship
  -- created some other way; a foreign key rather than a copy so the history
  -- cannot say something the request row does not.
  request_id uuid references public.friend_requests (id) on delete set null,
  primary key (wallet_a, wallet_b),
  constraint friendships_are_ordered check (wallet_a < wallet_b)
);

create index friendships_b_idx on public.friendships (wallet_b);

comment on table public.friendships is
  'Undirected. wallet_a < wallet_b is enforced, so one relationship is one row and a one-way friendship — the classic bug where clicking through to the other profile shows a stranger — cannot be written.';

-- Both halves of the graph as one directed view, because every query the app
-- actually writes is "who are MY friends" and expressing that against an ordered
-- pair at each call site is how a `wallet_b` gets forgotten.
create view public.friend_edges with (security_invoker = true) as
  select wallet_a as wallet, wallet_b as friend, since from public.friendships
  union all
  select wallet_b as wallet, wallet_a as friend, since from public.friendships;

comment on view public.friend_edges is
  'public.friendships seen from both sides. Query this rather than remembering to check wallet_a and wallet_b separately.';

-- ---------------------------------------------------------------------------
-- threads and messages
-- ---------------------------------------------------------------------------

create table public.threads (
  id              uuid primary key default gen_random_uuid(),
  participant_a   public.base58_address not null,
  participant_b   public.base58_address not null,
  created_at      timestamptz not null default now(),
  -- Denormalised so an inbox sorts without touching the messages table. Kept
  -- current by the trigger below rather than by every writer.
  last_message_at timestamptz,
  message_count   integer not null default 0 check (message_count >= 0),
  constraint threads_are_ordered check (participant_a < participant_b),
  unique (participant_a, participant_b)
);

create index threads_a_idx on public.threads (participant_a, last_message_at desc nulls last);
create index threads_b_idx on public.threads (participant_b, last_message_at desc nulls last);

comment on table public.threads is
  'Strictly two-party, canonically ordered. One conversation is one row whichever side opened it, so there is no "your copy" and "their copy" to fall out of step.';

create table public.messages (
  id        uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.threads (id) on delete cascade,
  sender    public.base58_address not null,
  -- MESSAGE_MAX in src/lib/social.ts. Long enough for a real pitch, short enough
  -- that one wallet cannot fill the table.
  body      text not null check (length(body) between 1 and 500),
  sent_at   timestamptz not null default now(),
  -- Set when the RECIPIENT reads it. A sender's own message is never unread to
  -- them, so there is no second column and no way for the two to disagree.
  read_at   timestamptz
);

create index messages_thread_idx on public.messages (thread_id, sent_at desc);
create index messages_unread_idx on public.messages (thread_id, sender) where read_at is null;

comment on column public.messages.read_at is
  'When the recipient read it. A thread has exactly two participants and a sender never reads their own message, so one nullable timestamp says everything a per-participant read table would.';

-- The sender has to be in the thread. A cross-table condition, so a trigger
-- rather than a check — and worth having, because the failure it prevents is
-- somebody else's mail appearing inside a conversation.
create or replace function public.guard_message_sender()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_a text;
  v_b text;
begin
  select participant_a, participant_b into v_a, v_b from public.threads where id = new.thread_id;
  if v_a is null then
    raise exception 'message %: no such thread', new.id;
  end if;
  if new.sender <> v_a and new.sender <> v_b then
    raise exception 'message %: sender is not a participant in that thread', new.id;
  end if;
  return new;
end;
$$;

create trigger messages_sender_must_be_a_participant
  before insert on public.messages
  for each row execute function public.guard_message_sender();

-- Keeps the thread's summary honest. In a trigger rather than in `send_message`,
-- so a row inserted by any route — a backfill, a repair, a second writer added
-- later — cannot leave the inbox sorting by a stale timestamp.
create or replace function public.touch_thread()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.threads
     set last_message_at = greatest(coalesce(last_message_at, new.sent_at), new.sent_at),
         message_count   = message_count + 1
   where id = new.thread_id;
  return new;
end;
$$;

create trigger messages_touch_thread
  after insert on public.messages
  for each row execute function public.touch_thread();

-- ---------------------------------------------------------------------------
-- trade_offers and their legs
-- ---------------------------------------------------------------------------

create table public.trade_offers (
  id        uuid primary key default gen_random_uuid(),
  sender    public.base58_address not null,
  recipient public.base58_address not null,
  note      text check (note is null or length(note) <= 500),
  status    text not null default 'pending'
              check (status in ('pending', 'accepted', 'declined', 'withdrawn', 'expired')),

  -- The $xNFT sweetener, in raw units, as TWO non-negative columns rather than
  -- one signed one.
  --
  -- `src/lib/social.ts` carries it as a signed number where negative means "the
  -- sender wants $xNFT back". That is compact and it is exactly the shape that
  -- produces an off-by-a-sign bug in a UI, because the sign has to be read
  -- correctly at every render and every comparison. Two columns make the
  -- direction a fact about which column is populated, and the check makes "both
  -- at once" — which would be two payments cancelling out — unrepresentable.
  sweetener_from_sender    public.u64_text not null default '0',
  sweetener_from_recipient public.u64_text not null default '0',

  created_at   timestamptz not null default now(),
  expires_at   timestamptz,
  responded_at timestamptz,

  constraint trade_offers_two_parties check (sender <> recipient),
  constraint trade_offers_one_direction_of_cash check (
    sweetener_from_sender = '0' or sweetener_from_recipient = '0'
  ),
  constraint trade_offers_resolved_has_timestamp check (
    (status = 'pending' and responded_at is null) or (status <> 'pending' and responded_at is not null)
  )
);

create index trade_offers_inbox_idx  on public.trade_offers (recipient, status, created_at desc);
create index trade_offers_outbox_idx on public.trade_offers (sender, status, created_at desc);
create index trade_offers_open_idx   on public.trade_offers (expires_at) where status = 'pending';

comment on table public.trade_offers is
  'A proposal, not a settlement. Accepting records a decision and moves nothing — there is no escrow anywhere in this protocol, so an offer that reassigned xployees would be a settlement layer hidden inside a messaging table.';

create table public.trade_offer_legs (
  offer_id   uuid   not null references public.trade_offers (id) on delete cascade,
  xployee_id bigint not null references public.xployees (id) on delete cascade,
  -- 'offered'   — the sender is putting this up.
  -- 'requested' — the sender wants it back.
  side       text   not null check (side in ('offered', 'requested')),
  -- (offer, xployee) as the key rather than (offer, side, xployee): the same unit
  -- cannot be on both sides of one trade, and this is what makes that impossible
  -- rather than merely checked by the writer that happens to insert the legs.
  primary key (offer_id, xployee_id)
);

create index trade_offer_legs_xployee_idx on public.trade_offer_legs (xployee_id);

comment on table public.trade_offer_legs is
  'The units on each side of an offer. The primary key is (offer, xployee), so the same worker cannot appear as both offered and requested in one trade.';

-- ---------------------------------------------------------------------------
-- Writers
-- ---------------------------------------------------------------------------

-- Every one resolves the actor through public.actor_wallet and none takes a
-- wallet address, so there is no writer that can be pointed at somebody else's
-- inbox. Each returns jsonb: a refusal here is an ordinary outcome the UI renders
-- as a sentence, not an exception.

-- The canonical pair, so ordering logic is written once.
create or replace function public.pair_key(p_x text, p_y text)
returns text[]
language sql immutable parallel safe strict set search_path = ''
as $$ select case when p_x < p_y then array[p_x, p_y] else array[p_y, p_x] end $$;